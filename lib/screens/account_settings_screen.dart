import 'dart:io';

import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import '../api/api_client.dart';
import '../auth/auth_repository.dart';
import '../beacon/auto_checkin_preference.dart';
import '../beacon/beacon_background.dart';
import '../config/app_config.dart';
import '../notifications/notification_service.dart';
import '../theme/theme_controller.dart';

class AccountSettingsScreen extends StatefulWidget {
  final AuthRepository authRepository;
  final ThemeController themeController;

  const AccountSettingsScreen({super.key, required this.authRepository, required this.themeController});

  @override
  State<AccountSettingsScreen> createState() => _AccountSettingsScreenState();
}

class _AccountSettingsScreenState extends State<AccountSettingsScreen> {
  final _api = ApiClient();

  bool _loading = true;
  String? _loadError;
  Map<String, dynamic>? _profile;

  // Device-local only -- there's no backend field for this (see
  // clubmanager's api/profile.php), since it's a per-device preference, not
  // a member-account setting. The actual scan loop lives in MainShell, which
  // reads this same AutoCheckinPreference flag.
  bool _autoCheckinEnabled = false;
  bool _togglingAutoCheckin = false;
  bool _checkinAlertsEnabled = false;
  bool _togglingCheckinAlerts = false;

  // Host-only (see the SwitchListTile's hasPermission gate below). Also
  // device-local -- see _autoCheckinEnabled's note above, same reasoning.
  bool _pendingPaymentAlertsEnabled = false;
  bool _togglingPendingPaymentAlerts = false;

  final _displayNameController = TextEditingController();
  final _phoneController = TextEditingController();
  bool _isOptOut = false;
  bool _savingSettings = false;
  String? _settingsError;

  bool _togglingAutoRenew = false;
  bool _togglingAutoApplyCredits = false;

  @override
  void initState() {
    super.initState();
    _load();
    _loadAutoCheckinPreference();
    _loadPendingPaymentAlertsPreference();
  }

  @override
  void dispose() {
    _displayNameController.dispose();
    _phoneController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _loadError = null;
    });

    final result = await widget.authRepository.authedCall(_api.getProfile);

    setState(() {
      _loading = false;
      if (result['statusCode'] == 200) {
        _profile = result;
        final contact = result['contact'] as Map<String, dynamic>;
        _displayNameController.text = contact['display_name'] as String;
        _phoneController.text = (contact['phone'] as String?) ?? '';
        _isOptOut = contact['is_opt_out'] as bool;
      } else {
        _loadError = result['error'] as String? ?? 'Could not load your settings.';
      }
    });
  }

  void _showResult(Map<String, dynamic> result, {String successMessage = 'Saved.'}) {
    final ok = result['success'] == true;
    final message = ok ? (result['message'] as String? ?? successMessage) : (result['error'] as String? ?? 'Something went wrong.');
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: ok ? null : Theme.of(context).colorScheme.error),
    );
  }

  Future<void> _saveSettings() async {
    setState(() {
      _savingSettings = true;
      _settingsError = null;
    });

    final result = await widget.authRepository.authedCall((token) => _api.postProfileAction(token, 'update_settings', {
          'display_name': _displayNameController.text.trim(),
          'phone': _phoneController.text.trim(),
          'is_opt_out': _isOptOut,
        }));

    setState(() {
      _savingSettings = false;
      if (result['success'] != true) {
        _settingsError = result['error'] as String? ?? 'Could not save your settings.';
      }
    });
    if (result['success'] == true) {
      _showResult(result, successMessage: 'Profile settings saved.');
      await _load();
    }
  }

  Future<void> _loadAutoCheckinPreference() async {
    final enabled = await AutoCheckinPreference.isEnabled();
    final alerts = await NotificationService.isCheckinAlertsEnabled();
    if (!mounted) return;
    setState(() {
      _autoCheckinEnabled = enabled;
      _checkinAlertsEnabled = alerts;
    });
  }

  /// Same shape as the other notification toggle: turning on has to clear the
  /// OS permission first and refuses if that's declined, so the switch never
  /// sits in an on position that silently does nothing.
  Future<void> _toggleCheckinAlerts(bool enabled) async {
    if (!enabled) {
      await NotificationService.setCheckinAlertsEnabled(false);
      setState(() => _checkinAlertsEnabled = false);
      return;
    }

    setState(() => _togglingCheckinAlerts = true);
    final granted = await NotificationService.requestPermission();
    if (!mounted) return;
    setState(() => _togglingCheckinAlerts = false);

    if (!granted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: const Text('Notification permission is blocked -- enable it for this app in system settings.'),
        backgroundColor: Theme.of(context).colorScheme.error,
        action: SnackBarAction(label: 'Open Settings', onPressed: openAppSettings),
      ));
      return;
    }

    await NotificationService.setCheckinAlertsEnabled(true);
    setState(() => _checkinAlertsEnabled = true);
  }

  /// Turning on requires location (and, on Android, Bluetooth scan/connect)
  /// permission up front -- no point flipping the preference on if the OS
  /// won't let beacon detection run once it exists. Turning off never needs
  /// a permission check.
  Future<void> _toggleAutoCheckin(bool enabled) async {
    if (!enabled) {
      await AutoCheckinPreference.setEnabled(false);
      // Also cancel any scan already registered with the OS, which would
      // otherwise outlive the preference and keep waking the phone.
      await BeaconBackground.stop();
      setState(() => _autoCheckinEnabled = false);
      return;
    }

    setState(() => _togglingAutoCheckin = true);
    bool granted;
    bool permanentlyDenied;
    var alwaysGranted = false;
    try {
      if (Platform.isIOS) {
        // Must request When-In-Use before Always: permission_handler_apple's
        // native side throws MISSING_WHENINUSE_PERMISSION synchronously if
        // Always is requested while authorization is still notDetermined
        // (i.e. on every fresh install), and with no try/catch around this
        // await that used to leave the spinner stuck forever.
        final whenInUse = await Permission.locationWhenInUse.request();
        granted = whenInUse.isGranted;
        permanentlyDenied = whenInUse.isPermanentlyDenied;

        if (granted) {
          // Best-effort only: iOS shows the "Always" upgrade prompt on its
          // own schedule and may not show it at all this session, and
          // permission_handler has no timeout of its own for that case --
          // bound it here so that outcome degrades to When-In-Use instead
          // of hanging the toggle a second way.
          try {
            final always = await Permission.locationAlways.request().timeout(const Duration(seconds: 10));
            alwaysGranted = always.isGranted;
          } catch (_) {
            alwaysGranted = false;
          }
        }
      } else {
        // On Android this has to be the Precise (ACCESS_FINE_LOCATION) grant
        // specifically -- see the AndroidManifest comment, including the
        // note that Android's own need for Precise here is assumed rather
        // than measured; an Approximate-only grant leaves Permission.location
        // denied, so the toggle refuses instead of switching on and then
        // never detecting anything.
        final statuses = await [Permission.bluetoothScan, Permission.bluetoothConnect, Permission.location].request();
        granted = statuses.values.every((s) => s.isGranted);
        permanentlyDenied = statuses.values.any((s) => s.isPermanentlyDenied);
      }
    } finally {
      if (mounted) setState(() => _togglingAutoCheckin = false);
    }
    if (!mounted) return;

    if (!granted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(permanentlyDenied
            ? '${Platform.isIOS ? 'Location is' : 'Bluetooth and Location are'} blocked -- enable ${Platform.isIOS ? 'it' : 'them'} for this app in system settings.'
            : Platform.isIOS
                ? 'Auto check-in needs Location access.'
                : 'Auto check-in needs Bluetooth and Precise Location. If Location is already allowed, set it to Precise rather than Approximate.'),
        backgroundColor: Theme.of(context).colorScheme.error,
        action: permanentlyDenied ? SnackBarAction(label: 'Open Settings', onPressed: openAppSettings) : null,
      ));
      return;
    }

    await AutoCheckinPreference.setEnabled(true);
    setState(() => _autoCheckinEnabled = true);

    if (Platform.isIOS && !alwaysGranted && mounted) {
      // Non-blocking, unlike the refusal above: the feature is genuinely on
      // and already works while the app is foregrounded. Only the
      // fully-closed case needs the "Always" upgrade, and iOS offers that
      // prompt on its own schedule rather than on demand.
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Auto Check-In is on. For it to check you in with the app fully closed, allow Location access "Always" when iOS asks again, or turn it on in system Settings.'),
        duration: Duration(seconds: 8),
      ));
    }

    // Asked for separately, and never allowed to block enabling: a check-in
    // that happens while the app is closed can only announce itself as a
    // notification, but it still happens without one. Declining costs the
    // confirmation, not the feature, and the Auto Check-In Notifications switch
    // that now appears is the way back to it.
    final notificationsGranted = await NotificationService.requestPermission();
    await NotificationService.setCheckinAlertsEnabled(notificationsGranted);
    if (!mounted) return;
    setState(() => _checkinAlertsEnabled = notificationsGranted);

    if (!notificationsGranted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text("Auto check-in is on. Without notification permission you won't be told when it checks you in while the app is closed."),
        duration: Duration(seconds: 6),
      ));
    }
  }

  Future<void> _loadPendingPaymentAlertsPreference() async {
    final enabled = await NotificationService.isPendingPaymentAlertsEnabled();
    if (!mounted) return;
    setState(() => _pendingPaymentAlertsEnabled = enabled);
  }

  /// Same shape as _toggleAutoCheckin: turning on requests the OS
  /// notification permission first and refuses to enable if it's denied;
  /// turning off never needs a permission check.
  Future<void> _togglePendingPaymentAlerts(bool enabled) async {
    if (!enabled) {
      await NotificationService.setPendingPaymentAlertsEnabled(false);
      setState(() => _pendingPaymentAlertsEnabled = false);
      return;
    }

    setState(() => _togglingPendingPaymentAlerts = true);
    final granted = await NotificationService.requestPermission();
    if (!mounted) return;
    setState(() => _togglingPendingPaymentAlerts = false);

    if (!granted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: const Text('Notification permission is required for pending-payment alerts -- enable it for this app in system settings.'),
        backgroundColor: Theme.of(context).colorScheme.error,
        action: SnackBarAction(label: 'Open Settings', onPressed: openAppSettings),
      ));
      return;
    }

    await NotificationService.setPendingPaymentAlertsEnabled(true);
    setState(() => _pendingPaymentAlertsEnabled = true);
  }

  Future<void> _toggleAutoRenew(bool enabled) async {
    setState(() => _togglingAutoRenew = true);
    final result = await widget.authRepository.authedCall(
      (token) => _api.postProfileAction(token, 'toggle_auto_renew', {'enabled': enabled}),
    );
    setState(() => _togglingAutoRenew = false);
    _showResult(result);
    if (result['success'] == true) await _load();
  }

  Future<void> _toggleAutoApplyCredits(bool enabled) async {
    setState(() => _togglingAutoApplyCredits = true);
    final result = await widget.authRepository.authedCall(
      (token) => _api.postProfileAction(token, 'toggle_auto_apply_credits', {'enabled': enabled}),
    );
    setState(() => _togglingAutoApplyCredits = false);
    _showResult(result);
    if (result['success'] == true) await _load();
  }

  Future<void> _sendPasswordReset() async {
    final result = await widget.authRepository.authedCall(
      (token) => _api.postProfileAction(token, 'trigger_password_reset'),
    );
    _showResult(result);
  }

  Future<void> _cancelEmailChange() async {
    final result = await widget.authRepository.authedCall(
      (token) => _api.postProfileAction(token, 'cancel_email_change'),
    );
    _showResult(result, successMessage: 'Pending email change cancelled.');
    if (result['success'] == true) await _load();
  }

  Future<void> _showChangeEmailDialog() async {
    final newEmailController = TextEditingController();
    final passwordController = TextEditingController();

    final requested = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Change Email Address'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: newEmailController,
              keyboardType: TextInputType.emailAddress,
              decoration: const InputDecoration(labelText: 'New Email Address'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: passwordController,
              obscureText: true,
              decoration: const InputDecoration(labelText: 'Current Password'),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(dialogContext).pop(false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.of(dialogContext).pop(true), child: const Text('Send Verification')),
        ],
      ),
    );

    if (requested != true) return;

    final result = await widget.authRepository.authedCall((token) => _api.postProfileAction(token, 'request_email_change', {
          'new_email': newEmailController.text.trim(),
          'current_password': passwordController.text,
        }));
    _showResult(result);
    if (result['success'] == true) await _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Account Settings')),
      body: _buildBody(context),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (_loading && _profile == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_loadError != null && _profile == null) {
      return Center(child: Text(_loadError!));
    }

    final contact = _profile!['contact'] as Map<String, dynamic>;
    final autoRenew = _profile!['auto_renew'] as bool;
    final canEnableAutoRenew = _profile!['can_enable_auto_renew'] as bool;
    final autoApplyCredits = _profile!['auto_apply_credits'] as bool;
    final pendingEmailChange = _profile!['pending_email_change'] as Map<String, dynamic>?;

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Profile Settings', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 12),
                TextField(
                  controller: _displayNameController,
                  decoration: const InputDecoration(labelText: 'Display Name'),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _phoneController,
                  keyboardType: TextInputType.phone,
                  decoration: const InputDecoration(labelText: 'Phone Number', hintText: 'Leave blank to remove'),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Opt out of bulk emails'),
                  value: _isOptOut,
                  onChanged: (v) => setState(() => _isOptOut = v),
                ),
                if (_settingsError != null) ...[
                  Text(_settingsError!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                  const SizedBox(height: 8),
                ],
                Align(
                  alignment: Alignment.centerRight,
                  child: FilledButton(
                    onPressed: _savingSettings ? null : _saveSettings,
                    child: _savingSettings
                        ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Text('Save'),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Email Address', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 8),
                Text(contact['email'] as String),
                if (pendingEmailChange != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    'Verification pending for ${pendingEmailChange['new_email']}.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton(onPressed: _cancelEmailChange, child: const Text('Cancel Pending Change')),
                  ),
                ] else
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton(onPressed: _showChangeEmailDialog, child: const Text('Change Email')),
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Theme', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 12),
                ListenableBuilder(
                  listenable: widget.themeController,
                  builder: (context, _) => SegmentedButton<ThemeMode>(
                    segments: const [
                      ButtonSegment(value: ThemeMode.light, label: Text('Light'), icon: Icon(Icons.light_mode_outlined)),
                      ButtonSegment(value: ThemeMode.dark, label: Text('Dark'), icon: Icon(Icons.dark_mode_outlined)),
                      ButtonSegment(value: ThemeMode.system, label: Text('System'), icon: Icon(Icons.settings_suggest_outlined)),
                    ],
                    selected: {widget.themeController.mode},
                    onSelectionChanged: (selected) => widget.themeController.setMode(selected.first),
                  ),
                ),
              ],
            ),
          ),
        ),
        if (Platform.isAndroid || Platform.isIOS) ...[
          const SizedBox(height: 16),
          Card(
            child: SwitchListTile(
              title: const Text('Auto Check-In (Bluetooth Beacon)'),
              subtitle: const Text(
                  "Check yourself in automatically when you arrive and your phone detects the club's Bluetooth beacon. Works with the app closed."),
              value: _autoCheckinEnabled,
              onChanged: _togglingAutoCheckin ? null : _toggleAutoCheckin,
              secondary: _togglingAutoCheckin ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2)) : null,
            ),
          ),
          // Only shown once auto check-in is on, since on its own it controls
          // nothing. Its real job is being a second chance: notification
          // permission is requested when auto check-in is switched on, and if
          // that was declined there'd otherwise be no way back to it from
          // inside the app.
          if (_autoCheckinEnabled) ...[
            const SizedBox(height: 8),
            Card(
              child: SwitchListTile(
                title: const Text('Auto Check-In Notifications'),
                subtitle: const Text(
                    'Tell me when auto check-in checks me in, or when it needs a payment first. With the app closed this is the only way to know either happened.'),
                value: _checkinAlertsEnabled,
                onChanged: _togglingCheckinAlerts ? null : _toggleCheckinAlerts,
                secondary: _togglingCheckinAlerts ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2)) : null,
              ),
            ),
          ],
        ],
        if (widget.authRepository.hasPermission('edit checkins')) ...[
          const SizedBox(height: 16),
          Card(
            child: SwitchListTile(
              title: const Text('Pending Payment Alerts'),
              subtitle: const Text('Buzz and notify me when a new cash payment needs approval while I\'m on the Hosting tab.'),
              value: _pendingPaymentAlertsEnabled,
              onChanged: _togglingPendingPaymentAlerts ? null : _togglePendingPaymentAlerts,
              secondary: _togglingPendingPaymentAlerts ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2)) : null,
            ),
          ),
        ],
        const SizedBox(height: 16),
        Card(
          child: SwitchListTile(
            title: const Text('Auto-Renew Membership'),
            subtitle: Text(canEnableAutoRenew ? 'Automatically charge your card on file at renewal.' : 'Add a card on file via the website to enable this.'),
            value: autoRenew,
            onChanged: (!canEnableAutoRenew || _togglingAutoRenew) ? null : _toggleAutoRenew,
          ),
        ),
        const SizedBox(height: 16),
        Card(
          child: SwitchListTile(
            title: const Text('Auto-Apply Membership Credits'),
            subtitle: const Text('Automatically redeem banked credits at renewal time.'),
            value: autoApplyCredits,
            onChanged: _togglingAutoApplyCredits ? null : _toggleAutoApplyCredits,
          ),
        ),
        const SizedBox(height: 16),
        Card(
          child: ListTile(
            title: const Text('Password'),
            subtitle: const Text('Send yourself a password reset email.'),
            trailing: FilledButton(onPressed: _sendPasswordReset, child: const Text('Send Reset Email')),
          ),
        ),
        const SizedBox(height: 32),
        // Deliberately separated from everything above (and off the home
        // screen entirely) -- logging out now clears a 30-day session, so an
        // accidental tap is costly enough to warrant its own space plus a
        // confirmation step, not sitting next to other buttons.
        OutlinedButton(
          style: OutlinedButton.styleFrom(foregroundColor: Theme.of(context).colorScheme.error),
          onPressed: _confirmLogout,
          child: const Text('Log Out'),
        ),
        // Spelled out rather than left to the corner ribbon so a bug report
        // can say which backend it came from, which matters here because the
        // same build writes real check-ins to whichever server it was
        // compiled against.
        if (AppConfig.label != null) ...[
          const SizedBox(height: 24),
          Text(
            '${AppConfig.label} build\n${ApiClient.baseUrl}',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ],
    );
  }

  Future<void> _confirmLogout() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Log Out?'),
        content: const Text("You'll need to sign in with your email and password again next time."),
        actions: [
          TextButton(onPressed: () => Navigator.of(dialogContext).pop(false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.of(dialogContext).pop(true), child: const Text('Log Out')),
        ],
      ),
    );
    if (confirmed == true) {
      await widget.authRepository.logout();
    }
  }
}
