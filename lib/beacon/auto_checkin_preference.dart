import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Device-local on/off flag for BLE auto check-in -- same pattern as
/// NotificationService's pending-payment-alerts flag. Shared between
/// AccountSettingsScreen (where it's toggled) and MainShell (where the
/// actual scanning loop reads it), so it lives here instead of inside either
/// screen.
class AutoCheckinPreference {
  static const _storage = FlutterSecureStorage();
  static const _key = 'auto_checkin_enabled';
  static const _lastAttemptDateKey = 'auto_checkin_last_attempt_date';

  static Future<bool> isEnabled() async {
    return (await _storage.read(key: _key)) == 'true';
  }

  static Future<void> setEnabled(bool enabled) async {
    await _storage.write(key: _key, value: enabled ? 'true' : 'false');
  }

  /// Local calendar day of the last auto check-in attempt that got a
  /// definitive answer from the server, as 'YYYY-MM-DD'.
  ///
  /// Persisted rather than held in memory so the "one automatic attempt per
  /// day" rule survives the app process being killed. Android reaps
  /// backgrounded apps freely, so an in-memory flag alone made the behaviour
  /// depend on whether the process happened to stay alive: come back after a
  /// kill and the phone would re-fire a check-in it had already done, earning
  /// an alarming "already checked in today" error from the server for a
  /// member who is perfectly checked in. One attempt per day also matches the
  /// backend's own dedupe (CheckinService::hasCheckedInToday). The manual
  /// Check-In tab stays available as the override for any case where a second
  /// attempt really is wanted, such as a host deleting a check-in.
  static Future<String?> lastAttemptDate() => _storage.read(key: _lastAttemptDateKey);

  static Future<void> setLastAttemptDate(String date) async {
    await _storage.write(key: _lastAttemptDateKey, value: date);
  }

  /// Today as the 'YYYY-MM-DD' key used by [lastAttemptDate].
  static String todayKey([DateTime? now]) {
    final d = now ?? DateTime.now();
    return '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
  }
}
