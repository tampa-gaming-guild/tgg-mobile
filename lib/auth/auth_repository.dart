import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:local_auth/local_auth.dart';

import '../api/api_client.dart';

enum AuthStatus { unknown, authenticated, unauthenticated }

/// Owns the mobile session: the short-lived access token (in memory only)
/// and the long-lived refresh token (device secure storage -- Keychain on
/// iOS, Keystore-backed EncryptedSharedPreferences on Android). Biometric
/// unlock gates *reading* the stored refresh token on relaunch; it isn't a
/// separate server-side auth path -- see the "biometric sign-in" note in the
/// project history for why that's sufficient (no backend changes needed).
class AuthRepository extends ChangeNotifier {
  final ApiClient _api;
  final FlutterSecureStorage _storage;
  final LocalAuthentication _localAuth;

  static const _refreshTokenKey = 'refresh_token';

  AuthStatus status = AuthStatus.unknown;
  String? accessToken;
  Map<String, dynamic>? user;
  String? lastError;

  AuthRepository({
    ApiClient? api,
    FlutterSecureStorage? storage,
    LocalAuthentication? localAuth,
  })  : _api = api ?? ApiClient(),
        _storage = storage ?? const FlutterSecureStorage(),
        _localAuth = localAuth ?? LocalAuthentication();

  /// Call once at app startup. Resolves to authenticated/unauthenticated
  /// after attempting to unlock and redeem any stored refresh token. A
  /// network failure leaves the stored token in place (falls back to the
  /// login screen but can self-heal next launch); only a clean rejection
  /// from the server (expired/revoked) clears it.
  Future<void> tryAutoLogin() async {
    final stored = await _storage.read(key: _refreshTokenKey);
    if (stored == null) {
      _setStatus(AuthStatus.unauthenticated);
      return;
    }

    if (!await _unlockWithBiometrics()) {
      _setStatus(AuthStatus.unauthenticated);
      return;
    }

    Map<String, dynamic>? result;
    try {
      result = await _api.refresh(stored);
    } on ApiConnectionException {
      _setStatus(AuthStatus.unauthenticated);
      return;
    }

    if (result == null) {
      await _storage.delete(key: _refreshTokenKey);
      _setStatus(AuthStatus.unauthenticated);
      return;
    }

    // The server rotates the refresh token on every redemption (issues a new
    // one, revokes this one) -- the replacement must be saved or the *next*
    // relaunch tries the now-dead token and gets rejected.
    await _storage.write(key: _refreshTokenKey, value: result['refresh_token'] as String);
    _applyTokenResult(result);
    _setStatus(AuthStatus.authenticated);
  }

  Future<bool> login(String email, String password) async {
    lastError = null;
    try {
      final result = await _api.login(email, password, deviceLabel: await _deviceLabel());
      await _storage.write(key: _refreshTokenKey, value: result['refresh_token'] as String);
      _applyTokenResult(result);
      _setStatus(AuthStatus.authenticated);
      return true;
    } on ApiException catch (e) {
      lastError = e.message;
      notifyListeners();
      return false;
    } catch (_) {
      lastError = 'Could not reach the server. Check your connection and try again.';
      notifyListeners();
      return false;
    }
  }

  Future<void> logout() async {
    final stored = await _storage.read(key: _refreshTokenKey);
    if (stored != null) {
      await _api.logout(stored);
    }
    await _storage.delete(key: _refreshTokenKey);
    accessToken = null;
    user = null;
    _setStatus(AuthStatus.unauthenticated);
  }

  /// Ensures a fresh access token before an authenticated call. Pass
  /// [forceRefresh] after a call comes back 401, to cover the token expiring
  /// mid-session (access tokens are short-lived by design).
  Future<String?> ensureAccessToken({bool forceRefresh = false}) async {
    if (accessToken != null && !forceRefresh) return accessToken;

    final stored = await _storage.read(key: _refreshTokenKey);
    if (stored == null) return null;

    Map<String, dynamic>? result;
    try {
      result = await _api.refresh(stored);
    } on ApiConnectionException {
      return null; // transient -- stored token is left untouched for the next attempt
    }
    if (result == null) return null;

    await _storage.write(key: _refreshTokenKey, value: result['refresh_token'] as String);
    _applyTokenResult(result);
    notifyListeners();
    return accessToken;
  }

  void _applyTokenResult(Map<String, dynamic> result) {
    accessToken = result['access_token'] as String;
    user = result['user'] as Map<String, dynamic>?;
  }

  void _setStatus(AuthStatus newStatus) {
    status = newStatus;
    notifyListeners();
  }

  /// True if biometrics aren't set up on this device at all (nothing to gate
  /// with -- don't block using the stored session) or if the prompt
  /// succeeds. False only when the device *can* prompt and the user fails or
  /// cancels it -- that's the one case that should fall back to a full
  /// email/password login instead of silently bypassing the gate.
  Future<bool> _unlockWithBiometrics() async {
    bool canUseBiometrics;
    try {
      canUseBiometrics = await _localAuth.isDeviceSupported() && await _localAuth.canCheckBiometrics;
      if (canUseBiometrics) {
        final available = await _localAuth.getAvailableBiometrics();
        canUseBiometrics = available.isNotEmpty;
      }
    } catch (_) {
      canUseBiometrics = false;
    }

    if (!canUseBiometrics) return true;

    try {
      return await _localAuth.authenticate(
        localizedReason: 'Unlock to sign in to TGG',
        biometricOnly: true,
        persistAcrossBackgrounding: true,
      );
    } catch (_) {
      return false;
    }
  }

  Future<String> _deviceLabel() async {
    // Keeping this simple for now (no device_info_plus dependency) -- good
    // enough to tell devices apart in a future "manage devices" screen.
    return 'Android device';
  }
}
