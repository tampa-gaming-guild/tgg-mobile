import 'dart:async';

import 'package:permission_handler/permission_handler.dart';

import '../api/api_client.dart';
import '../auth/auth_repository.dart';
import 'auto_checkin_preference.dart';
import 'beacon_scanner.dart';
import 'club_beacon.dart';
import 'ibeacon_reading.dart';

/// Drives BLE scanning for the club's beacon and fires the same check-in
/// call CheckInScreen's button does. Owned by MainShell, which decides *when*
/// scanning should run (checkin window open, preference on, app foregrounded
/// -- see MainShell's _syncAutoCheckin).
///
/// At most one automatic check-in attempt happens per calendar day, tracked
/// via AutoCheckinPreference.lastAttemptDate so the rule holds even if the
/// app process is killed and relaunched mid-session (see that field's note
/// for why in-memory alone was wrong). Once the day is marked, scanning stops
/// and stays stopped: MainShell's periodic status refresh and its
/// resume-from-background hook both call [sync] again, and without consulting
/// that state they would restart the radio to do nothing at all.
///
/// A transport-level failure (offline, DNS, timeout) deliberately does *not*
/// consume the day's attempt -- that's a common condition at a venue, and
/// burning the attempt on it would leave the member silently un-checked-in
/// with no retry for the whole session. Those retry after
/// [_transportRetryCooldown]; only a definitive answer from the server ends
/// the day's attempts.
///
/// No guest-bring-along support here (unlike CheckInScreen's manual flow) --
/// there's no one to ask. A beacon-triggered check-in is always solo.
class AutoCheckinController {
  static const _transportRetryCooldown = Duration(seconds: 30);

  final AuthRepository authRepository;
  final void Function(String message, {required bool isError}) onResult;
  final void Function(String reason) onNeedsPayment;

  AutoCheckinController({required this.authRepository, required this.onResult, required this.onNeedsPayment});

  final _api = ApiClient();
  StreamSubscription<List<IBeaconReading>>? _sub;
  bool _scanning = false;
  bool _inFlight = false;
  DateTime? _retryNotBefore;

  Future<bool> _attemptedToday() async {
    return (await AutoCheckinPreference.lastAttemptDate()) == AutoCheckinPreference.todayKey();
  }

  /// Idempotent: starts scanning when [shouldScan] and today's attempt hasn't
  /// been used yet, stops it otherwise. Silently does nothing if the
  /// Bluetooth/Location permissions aren't granted -- MainShell only ever
  /// calls this because the user opted in via Account Settings, where
  /// granting them is already required to flip the preference on, so a
  /// missing grant here just means it was later revoked in system settings,
  /// not a case worth surfacing an error for from the background.
  Future<void> sync(bool shouldScan) async {
    final wantScan = shouldScan && !await _attemptedToday();

    if (wantScan && !_scanning) {
      final scanGranted = await Permission.bluetoothScan.isGranted;
      final connectGranted = await Permission.bluetoothConnect.isGranted;
      final locationGranted = await Permission.location.isGranted;
      if (!scanGranted || !connectGranted || !locationGranted) return;

      _sub = BeaconScanner.readings.listen(_onReadings);
      await BeaconScanner.startScan();
      _scanning = true;
    } else if (!wantScan && _scanning) {
      await _stop();
    }
  }

  Future<void> stop() => sync(false);

  Future<void> _stop() async {
    await _sub?.cancel();
    _sub = null;
    await BeaconScanner.stopScan();
    _scanning = false;
  }

  Future<void> _onReadings(List<IBeaconReading> readings) async {
    if (_inFlight) return;
    if (_retryNotBefore != null && DateTime.now().isBefore(_retryNotBefore!)) return;
    if (!readings.any((r) => r.uuid == ClubBeacon.uuid)) return;
    if (await _attemptedToday()) {
      await _stop();
      return;
    }

    _inFlight = true;
    try {
      final result = await authRepository.authedCall((token) => _api.checkIn(token, guestNames: const []));

      // Never reached the server (token refresh couldn't connect); same
      // treatment as the thrown transport failure below.
      if (result['offline'] == true) {
        _retryNotBefore = DateTime.now().add(_transportRetryCooldown);
        return;
      }

      // Reached the server, so the day's automatic attempt is spent whatever
      // the verdict was -- retrying a refusal would just repeat it.
      await AutoCheckinPreference.setLastAttemptDate(AutoCheckinPreference.todayKey());
      await _stop();

      if (result['success'] == true) {
        onResult(result['message'] as String? ?? "You're checked in!", isError: false);
      } else if (result['redirect_reason'] != null) {
        onNeedsPayment(result['redirect_reason'] as String);
      } else {
        onResult(result['error'] as String? ?? 'Auto check-in failed.', isError: true);
      }
    } catch (_) {
      // Never reached the server: keep scanning and let a later advertisement
      // try again, rather than spending the day's attempt on a network blip.
      // The beacon advertises about once a second, hence the cooldown.
      _retryNotBefore = DateTime.now().add(_transportRetryCooldown);
    } finally {
      _inFlight = false;
    }
  }
}
