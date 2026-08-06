import 'dart:ui';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../api/api_client.dart';
import '../auth/auth_repository.dart';
import '../notifications/notification_service.dart';
import 'auto_checkin_preference.dart';
import 'club_beacon.dart';

/// Background half of beacon auto check-in: the part that runs when the club
/// beacon is spotted while the app is backgrounded or not running at all.
///
/// Android keeps scanning for us after the process dies (see
/// BeaconScanControl.kt) and starts the app just far enough to deliver a
/// broadcast, which spins up a headless Flutter engine pointed at
/// [beaconBackgroundEntrypoint]. There is no UI, no MainShell and no
/// AuthRepository instance to inherit here, so this rebuilds what it needs
/// from device storage and reports via a notification rather than a snackbar.
class BeaconBackground {
  // These strings must match CONTROL_CHANNEL in BeaconBackgroundChannel.kt and
  // BACKGROUND_CHANNEL in BeaconBackgroundRunner.kt exactly. They are opaque
  // names, so a mismatch compiles and launches cleanly and then simply never
  // delivers a call -- change both sides together.
  static const _channel = MethodChannel('com.tampagamingguild.tggmobile/beacon_control');
  static const backgroundChannel = MethodChannel('com.tampagamingguild.tggmobile/beacon_background');

  /// Arms detection. Safe to call repeatedly; re-registering replaces the
  /// existing scan rather than stacking another one.
  static Future<void> start() async {
    final handle = PluginUtilities.getCallbackHandle(beaconBackgroundEntrypoint);
    if (handle == null) return;

    try {
      await _channel.invokeMethod('registerCallback', {'handle': handle.toRawHandle()});
      final failure = await _channel.invokeMethod<String>('startScan', {'uuid': ClubBeacon.uuid});
      if (failure != null) {
        debugPrint('Background beacon scan not started: $failure');
      }
    } on MissingPluginException {
      // Neither Android nor iOS has a handler registered for this channel.
    } on PlatformException catch (e) {
      debugPrint('Background beacon scan not started: ${e.message}');
    }
  }

  static Future<void> stop() async {
    try {
      await _channel.invokeMethod('stopScan');
    } on MissingPluginException {
      // Neither Android nor iOS has a handler registered for this channel.
    } on PlatformException {
      // Adapter gone or permission revoked; the scan is not running either way.
    }
  }

  /// The actual check-in, mirroring AutoCheckinController's rules: one
  /// automatic attempt per day, and a transport failure must not spend it.
  /// Deliberately does not consult the check-in window first -- that would be
  /// a second round trip before the one that matters, and checkins.php
  /// already refuses politely outside a session.
  static Future<void> runCheckIn() async {
    if (await AutoCheckinPreference.lastAttemptDate() == AutoCheckinPreference.todayKey()) return;
    if (!await AutoCheckinPreference.isEnabled()) return;
    if (await AutoCheckinPreference.inRetryCooldown()) return;

    final auth = AuthRepository();
    final api = ApiClient();

    final Map<String, dynamic> result;
    try {
      result = await auth.authedCall((token) => api.checkIn(token, guestNames: const []));
    } catch (_) {
      return; // never reached the server; leave the day's attempt unspent
    }
    if (result['offline'] == true) return;

    // The window isn't open yet -- the member arrived early. Unlike every other
    // verdict this one expires on its own, so the day's attempt stays unspent
    // and the scan stays registered; back off instead, and let a later sighting
    // try again once the window has opened. Spending the day here was the old
    // behaviour, and it silently stranded anyone who showed up more than an
    // hour before the session (check-in opens 1h ahead) -- hosts, mostly.
    if (result['code'] == 'no_session_open') {
      debugPrint('Beacon detected before the check-in window opened; backing off and staying armed.');
      await AutoCheckinPreference.setRetryNotBefore(
        DateTime.now().add(AutoCheckinPreference.retryCooldown),
      );
      return;
    }

    await AutoCheckinPreference.clearRetryNotBefore();
    await AutoCheckinPreference.setLastAttemptDate(AutoCheckinPreference.todayKey());
    // The registered scan reports every sighting, so without this the OS
    // would keep waking us for as long as the member stays in the building,
    // each time only to find the day already stamped. MainShell re-arms on
    // the next background transition, which for a new day is what we want.
    await stop();

    if (!await NotificationService.isCheckinAlertsEnabled()) return;

    await NotificationService.init();
    if (result['success'] == true) {
      await NotificationService.show(
        title: 'Checked In!',
        body: result['message'] as String? ?? "You're checked in for today's session.",
      );
    } else if (result['redirect_reason'] != null) {
      await NotificationService.show(
        title: 'Payment Needed to Check In',
        body: 'The club beacon was detected, but a payment is needed before you can check in. Open the app to finish.',
      );
    }
    // A plain refusal (e.g. already checked in) stays silent: nobody asked
    // for this, so it shouldn't interrupt with a non-problem. (no_session_open
    // never reaches here -- it returns above, before the day is stamped.)
  }
}

/// Headless entrypoint started by BeaconBackgroundRunner.kt. Must be a
/// top-level function and marked for AOT retention, since nothing in the Dart
/// code ever calls it and tree shaking would otherwise drop it.
@pragma('vm:entry-point')
void beaconBackgroundEntrypoint() {
  WidgetsFlutterBinding.ensureInitialized();

  BeaconBackground.backgroundChannel.setMethodCallHandler((call) async {
    if (call.method != 'onBeaconDetected') return null;
    try {
      await BeaconBackground.runCheckIn();
    } finally {
      // Always report back: the native side holds the broadcast open and
      // keeps the engine alive until it hears this.
      await BeaconBackground.backgroundChannel.invokeMethod('backgroundHandlerDone');
    }
    return null;
  });

  // Native waits for this before sending onBeaconDetected, so a detection
  // can't be delivered into a handler that isn't listening yet.
  BeaconBackground.backgroundChannel.invokeMethod('backgroundHandlerReady');
}
