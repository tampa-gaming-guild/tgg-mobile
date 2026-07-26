import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:permission_handler/permission_handler.dart';

/// Thin wrapper around flutter_local_notifications for the one thing this
/// app currently notifies about: a new pending cash payment while a host is
/// on the Hosting tab (see HostScreen). Local-only -- no FCM/APNs, so it only
/// ever fires while the app process is actually alive and polling; there's
/// no server-push path here.
///
/// Opt-in, same pattern as Account Settings' Auto Check-In toggle: the
/// preference is device-local (no backend field) and turning it on is what
/// triggers the OS permission request, not app startup.
class NotificationService {
  static const _storage = FlutterSecureStorage();
  static const _pendingPaymentAlertsKey = 'pending_payment_alerts_enabled';

  static final _plugin = FlutterLocalNotificationsPlugin();
  static bool _initialized = false;
  static int _nextId = 0;

  static Future<void> init() async {
    if (_initialized) return;
    _initialized = true;

    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    const darwin = DarwinInitializationSettings(
      requestAlertPermission: false, // requested explicitly via requestPermission() instead
      requestBadgePermission: false,
      requestSoundPermission: false,
    );
    await _plugin.initialize(settings: const InitializationSettings(android: android, iOS: darwin));
  }

  static Future<bool> isPendingPaymentAlertsEnabled() async {
    return (await _storage.read(key: _pendingPaymentAlertsKey)) == 'true';
  }

  static Future<void> setPendingPaymentAlertsEnabled(bool enabled) async {
    await _storage.write(key: _pendingPaymentAlertsKey, value: enabled ? 'true' : 'false');
  }

  /// Requests the OS notification permission (Android 13+; iOS's alert/badge/
  /// sound trio). Returns whether it's actually granted, so the Settings
  /// toggle can refuse to turn on if the user denies it.
  static Future<bool> requestPermission() async {
    final status = await Permission.notification.request();
    return status.isGranted;
  }

  static Future<void> show({required String title, required String body}) async {
    const androidDetails = AndroidNotificationDetails(
      'pending_payments',
      'Pending Cash Payments',
      channelDescription: 'Alerts a host when a new cash payment needs approval',
      importance: Importance.high,
      priority: Priority.high,
    );
    const darwinDetails = DarwinNotificationDetails(presentAlert: true, presentBadge: true, presentSound: true);

    await _plugin.show(
      id: _nextId++,
      title: title,
      body: body,
      notificationDetails: const NotificationDetails(android: androidDetails, iOS: darwinDetails),
    );
  }
}
