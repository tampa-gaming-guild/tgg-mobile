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
  static const _retryNotBeforeKey = 'auto_checkin_retry_not_before';

  /// How long to wait before trying again after the server says the check-in
  /// window isn't open yet. Short enough that a member who arrived early is
  /// checked in soon after the window opens, long enough that sitting in the
  /// building beforehand doesn't spin up a headless engine every few seconds.
  static const retryCooldown = Duration(minutes: 10);

  static Future<bool> isEnabled() async {
    return (await _storage.read(key: _key)) == 'true';
  }

  static Future<void> setEnabled(bool enabled) async {
    await _storage.write(key: _key, value: enabled ? 'true' : 'false');
    // Turning the feature on is an explicit "try now", so don't leave a
    // pending backoff from an earlier session sitting in the way.
    if (enabled) await clearRetryNotBefore();
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

  /// Earliest time the next automatic attempt may run, or null if there is no
  /// cooldown pending.
  ///
  /// Set when the server reports the check-in window isn't open yet, which is
  /// the one refusal that resolves itself: a member who walks in before the
  /// window opens must still be picked up once it does. That case deliberately
  /// leaves [lastAttemptDate] unstamped, so this is what keeps the retries from
  /// hammering -- and it is persisted rather than held in memory because the
  /// background path runs in a process that dies between beacon sightings, so
  /// an in-memory cooldown would reset on every single wakeup.
  static Future<DateTime?> retryNotBefore() async {
    final raw = await _storage.read(key: _retryNotBeforeKey);
    return raw == null ? null : DateTime.tryParse(raw);
  }

  static Future<void> setRetryNotBefore(DateTime when) async {
    await _storage.write(key: _retryNotBeforeKey, value: when.toIso8601String());
  }

  static Future<void> clearRetryNotBefore() async {
    await _storage.delete(key: _retryNotBeforeKey);
  }

  /// True when a cooldown from [setRetryNotBefore] is still in effect.
  static Future<bool> inRetryCooldown([DateTime? now]) async {
    final until = await retryNotBefore();
    if (until == null) return false;
    return (now ?? DateTime.now()).isBefore(until);
  }

  /// Today as the 'YYYY-MM-DD' key used by [lastAttemptDate].
  static String todayKey([DateTime? now]) {
    final d = now ?? DateTime.now();
    return '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
  }
}
