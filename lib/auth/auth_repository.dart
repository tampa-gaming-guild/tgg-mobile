import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../api/api_client.dart';

enum AuthStatus { unknown, authenticated, unauthenticated }

/// Owns the mobile session: the short-lived access token (in memory only)
/// and the long-lived (30-day, server-enforced) refresh token in device
/// secure storage (Keychain on iOS, Keystore-backed
/// EncryptedSharedPreferences on Android). Session resumption is silent --
/// no biometric/interactive gate -- by design: the beacon-triggered
/// auto-check-in has to be able to obtain a valid access token with nobody
/// present to respond to a prompt, so nothing in the token-refresh path can
/// require user interaction. A device-lock/app-lock feature, if wanted
/// later, would need to be a separate UI-only layer that doesn't sit in
/// front of this.
class AuthRepository extends ChangeNotifier {
  final ApiClient _api;
  final FlutterSecureStorage _storage;

  static const _refreshTokenKey = 'refresh_token';

  AuthStatus status = AuthStatus.unknown;
  String? accessToken;
  Map<String, dynamic>? user;
  String? lastError;

  AuthRepository({
    ApiClient? api,
    FlutterSecureStorage? storage,
  })  : _api = api ?? ApiClient(),
        _storage = storage ?? const FlutterSecureStorage();

  /// 'all' is the superadmin/admin catch-all permission, same shorthand the
  /// backend itself uses (has_permission() in config/bootstrap.php).
  bool hasPermission(String permission) {
    final permissions = (user?['permissions'] as List<dynamic>?)?.cast<String>() ?? const [];
    return permissions.contains('all') || permissions.contains(permission);
  }

  /// Call once at app startup. Resolves to authenticated/unauthenticated
  /// after attempting to silently redeem any stored refresh token. A
  /// network failure leaves the stored token in place (falls back to the
  /// login screen but can self-heal next launch); only a clean rejection
  /// from the server (expired/revoked) clears it.
  Future<void> tryAutoLogin() async {
    final stored = await _storage.read(key: _refreshTokenKey);
    if (stored == null) {
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

  /// Runs an authenticated API call, refreshing the access token first if
  /// needed and retrying once if the token turned out to be expired
  /// mid-session (statusCode 401). Centralizes this so screens (check-in,
  /// profile, settings) don't each reimplement the same retry dance.
  /// Returns a synthetic 401 result if there's no session to authenticate
  /// with at all, after signing the user out.
  Future<Map<String, dynamic>> authedCall(Future<Map<String, dynamic>> Function(String accessToken) call) async {
    final token = await ensureAccessToken();
    if (token == null) {
      await logout();
      return {'statusCode': 401, 'error': 'Your session expired. Please sign in again.'};
    }

    var result = await call(token);
    if (result['statusCode'] == 401) {
      final refreshed = await ensureAccessToken(forceRefresh: true);
      if (refreshed != null) {
        result = await call(refreshed);
      }
    }
    return result;
  }

  void _applyTokenResult(Map<String, dynamic> result) {
    accessToken = result['access_token'] as String;
    user = result['user'] as Map<String, dynamic>?;
  }

  void _setStatus(AuthStatus newStatus) {
    status = newStatus;
    notifyListeners();
  }

  Future<String> _deviceLabel() async {
    // Keeping this simple for now (no device_info_plus dependency) -- good
    // enough to tell devices apart in a future "manage devices" screen.
    return 'Android device';
  }
}
