import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api/api_client.dart';
import '../auth/auth_repository.dart';
import '../notifications/notification_service.dart';
import 'member_profile_screen.dart';
import 'payment_flow_screen.dart';

/// The Hosting tab, mirroring index.php's Hosting View: session banner,
/// today's check-in count, pending cash approvals, quick member search +
/// check-in, and the check-ins log. Only shown in the bottom nav while a
/// session is active and the caller holds 'edit checkins' (see MainShell),
/// and it's the default tab in that case.
///
/// [isActive] tells this widget whether its tab is the one currently on
/// screen -- MainShell keeps every tab alive in an IndexedStack, so
/// switching tabs doesn't dispose/recreate this widget. The pending-payment
/// poll itself always runs regardless (a host needs the alert no matter
/// which tab they're looking at); isActive only decides whether to refresh
/// immediately on becoming visible, and whether the in-app SnackBar is shown
/// (a SnackBar on a tab that isn't painted right now wouldn't be seen
/// anyway -- the haptic buzz and system notification aren't affected by that
/// and always fire).
class HostScreen extends StatefulWidget {
  final AuthRepository authRepository;
  final bool isActive;

  const HostScreen({super.key, required this.authRepository, required this.isActive});

  @override
  State<HostScreen> createState() => _HostScreenState();
}

class _HostScreenState extends State<HostScreen> {
  // Cheap enough at this volume (one host or two, at most, polling a single
  // GET) to catch a new pending cash payment reasonably quickly without
  // needing push notifications.
  static const _pollInterval = Duration(seconds: 20);

  final _api = ApiClient();
  final _searchController = TextEditingController();
  Timer? _debounce;
  Timer? _pollTimer;

  bool _searching = false;
  List<dynamic> _searchResults = const [];
  int? _checkingInContactId;

  bool _loadingDashboard = true;
  String? _dashboardError;
  bool _isHostingNow = false;
  Map<String, dynamic>? _activeSession;
  int _checkinsToday = 0;
  List<dynamic> _pendingPayments = const [];
  List<dynamic> _checkinsLog = const [];
  final Set<int> _resolvingPaymentIds = {};
  int? _deletingCheckinId;

  // Tracks which pending-payment ids we've already seen, so a poll can tell
  // "a new one just showed up" apart from "the same ones are still here" --
  // null until the first successful load, so that initial load never fires
  // a false "new payment" alert for payments that were already pending.
  Set<int>? _knownPendingPaymentIds;

  @override
  void initState() {
    super.initState();
    _loadDashboard();
    // Runs for as long as this widget exists (i.e. for the whole logged-in
    // session while Hosting is available), not just while its tab is
    // visible -- see the isActive doc comment above.
    _pollTimer = Timer.periodic(_pollInterval, (_) => _loadDashboard(silent: true));
  }

  @override
  void didUpdateWidget(covariant HostScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isActive && !oldWidget.isActive) {
      _loadDashboard(silent: true); // catch up on anything missed while this tab wasn't visible
    }
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _debounce?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  /// [silent] skips the loading spinner -- used by the poll timer and the
  /// just-became-active refresh, so a background/periodic check doesn't
  /// flash the dashboard content every time.
  Future<void> _loadDashboard({bool silent = false}) async {
    if (!silent) {
      setState(() {
        _loadingDashboard = true;
        _dashboardError = null;
      });
    }

    final result = await widget.authRepository.authedCall(_api.hostDashboard);
    if (!mounted) return;

    setState(() {
      _loadingDashboard = false;
      if (result['statusCode'] != 200) {
        if (!silent) _dashboardError = result['error'] as String? ?? 'Could not load the hosting dashboard.';
        return;
      }
      _dashboardError = null;
      _isHostingNow = result['is_hosting_now'] == true;
      _activeSession = result['active_session'] as Map<String, dynamic>?;
      _checkinsToday = (result['checkins_today'] as int?) ?? 0;
      _pendingPayments = (result['pending_payments'] as List<dynamic>?) ?? const [];
      _checkinsLog = (result['checkins_log'] as List<dynamic>?) ?? const [];
    });

    _notifyIfNewPendingPayments();
  }

  /// Notifies (system notification + haptic, and a snackbar if this tab is
  /// actually the visible one) for any pending payment id that wasn't in the
  /// previous load -- the closest thing to a push notification we get
  /// without standing up FCM/APNs, and it fires no matter which tab the app
  /// is on since the poll now runs continuously (see initState). Gated on
  /// the Account Settings "Pending Payment Alerts" toggle -- if it's off,
  /// this stays completely silent.
  Future<void> _notifyIfNewPendingPayments() async {
    final currentIds = _pendingPayments.map((p) => (p as Map<String, dynamic>)['id'] as int).toSet();
    final previousIds = _knownPendingPaymentIds;
    _knownPendingPaymentIds = currentIds;
    if (previousIds == null) return; // first load this session -- nothing to compare against yet

    final newIds = currentIds.difference(previousIds);
    if (newIds.isEmpty) return;

    if (!await NotificationService.isPendingPaymentAlertsEnabled()) return;
    if (!mounted) return;

    final newNames = _pendingPayments
        .where((p) => newIds.contains((p as Map<String, dynamic>)['id']))
        .map((p) => (p as Map<String, dynamic>)['display_name'] as String)
        .join(', ');

    HapticFeedback.vibrate();
    NotificationService.show(
      title: 'Cash Payment Pending Approval',
      body: newIds.length == 1 ? '$newNames needs approval.' : '$newNames need approval.',
    );
    if (!widget.isActive) return; // not the visible tab -- a snackbar here wouldn't be seen anyway
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('New cash payment pending approval: $newNames'),
      duration: const Duration(seconds: 6),
    ));
  }

  void _onSearchChanged(String query) {
    _debounce?.cancel();
    if (query.trim().length < 2) {
      setState(() => _searchResults = const []);
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 300), () => _runSearch(query.trim()));
  }

  Future<void> _runSearch(String query) async {
    setState(() => _searching = true);
    final results = await widget.authRepository.authedCall((token) async {
      final list = await _api.hostSearch(token, query);
      // hostSearch already returns [] on a non-200/permission failure;
      // wrap so authedCall's 401-retry still has a statusCode to inspect.
      return {'results': list, 'statusCode': 200};
    });
    if (!mounted) return;
    setState(() {
      _searching = false;
      _searchResults = (results['results'] as List<dynamic>?) ?? const [];
    });
  }

  /// Opens the guest-pass confirmation dialog before actually checking
  /// someone in, mirroring host_checkin.php's guest-confirm panel.
  Future<void> _openCheckInConfirm(int contactId, String displayName) async {
    final guestNames = await showDialog<List<String>>(
      context: context,
      builder: (_) => _GuestConfirmDialog(api: _api, authRepository: widget.authRepository, contactId: contactId, displayName: displayName),
    );
    if (guestNames == null) return; // dialog was cancelled
    await _checkIn(contactId, displayName, guestNames: guestNames);
  }

  Future<void> _checkIn(int contactId, String displayName, {List<String> guestNames = const []}) async {
    setState(() => _checkingInContactId = contactId);
    final result = await widget.authRepository.authedCall((token) => _api.hostCheckIn(token, contactId, guestNames: guestNames));
    if (!mounted) return;
    setState(() => _checkingInContactId = null);

    if (result['redirect_reason'] != null) {
      await _openPaymentFlow(contactId, displayName, result['redirect_reason'] as String);
      return;
    }

    final ok = result['success'] == true;
    // Not result['message'] on success -- that's worded for self-check-in
    // ("Welcome, X!"), which reads backwards on the host's own screen.
    final message = ok ? '$displayName checked in successfully.' : (result['error'] as String? ?? 'Check-in failed.');
    _showSnack(message, isError: !ok);

    if (ok) {
      _searchController.clear();
      setState(() => _searchResults = const []);
      await _loadDashboard();
    }
  }

  /// Opens the native Card/Cash (+ tier picker) screen -- mirrors
  /// host_checkin.php's redirect into pay-entrance.php, but the webview
  /// only ever shows for Stripe's own hosted Checkout page inside it, not
  /// this picker itself. A successful card payment there also completes
  /// the check-in itself (the backend inserts the tgg_checkins row); cash
  /// instead lands on the pending-approvals list already shown on this
  /// dashboard.
  Future<void> _openPaymentFlow(int contactId, String displayName, String reason) async {
    final outcome = await Navigator.of(context).push<String>(
      MaterialPageRoute(
        builder: (_) => PaymentFlowScreen(
          authRepository: widget.authRepository,
          displayName: displayName,
          initialReason: reason,
          contactId: contactId,
        ),
      ),
    );
    if (!mounted) return;

    if (outcome == 'success') {
      _searchController.clear();
      setState(() => _searchResults = const []);
      _showSnack('$displayName checked in successfully.');
      await _loadDashboard();
    } else if (outcome == 'cash_pending') {
      _searchController.clear();
      setState(() => _searchResults = const []);
      _showSnack('$displayName has a pending cash payment -- approve it below to complete their check-in.');
      await _loadDashboard();
    }
  }

  Future<void> _resolvePayment(int pendingId, String action, String displayName) async {
    setState(() => _resolvingPaymentIds.add(pendingId));
    final result = await widget.authRepository.authedCall((token) => _api.resolvePendingPayment(token, pendingId, action));
    if (!mounted) return;
    setState(() => _resolvingPaymentIds.remove(pendingId));

    final ok = result['success'] == true;
    _showSnack(ok ? (result['message'] as String? ?? 'Done.') : (result['error'] as String? ?? 'Could not process this payment.'), isError: !ok);

    if (ok) await _loadDashboard();
  }

  Future<void> _confirmDeleteCheckin(int checkinId, String displayName) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete Check-In?'),
        content: Text("Remove $displayName's check-in from today's log?"),
        actions: [
          TextButton(onPressed: () => Navigator.of(dialogContext).pop(false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.error),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    setState(() => _deletingCheckinId = checkinId);
    final result = await widget.authRepository.authedCall((token) => _api.deleteCheckin(token, checkinId));
    if (!mounted) return;
    setState(() => _deletingCheckinId = null);

    final ok = result['success'] == true;
    if (!ok) {
      _showSnack(result['error'] as String? ?? 'Could not delete this check-in.', isError: true);
    } else {
      await _loadDashboard();
    }
  }

  void _showSnack(String message, {bool isError = false}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: isError ? Theme.of(context).colorScheme.error : null),
    );
  }

  String _formatTimeRange(String startIso, String endIso) {
    return '${_formatTime(startIso)} – ${_formatTime(endIso)}';
  }

  String _formatTime(String iso) {
    final dt = DateTime.parse(iso);
    final hour12 = dt.hour % 12 == 0 ? 12 : dt.hour % 12;
    final minute = dt.minute.toString().padLeft(2, '0');
    final period = dt.hour < 12 ? 'AM' : 'PM';
    return '$hour12:$minute $period';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Host Dashboard')),
      body: RefreshIndicator(
        onRefresh: _loadDashboard,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            if (_loadingDashboard) const Center(child: Padding(padding: EdgeInsets.all(24), child: CircularProgressIndicator())),
            if (_dashboardError != null) Text(_dashboardError!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
            if (_activeSession != null) ...[
              Card(
                child: ListTile(
                  title: Text(_isHostingNow ? 'Hosting: ${_activeSession!['title']}' : "Today's Session: ${_activeSession!['title']}"),
                  subtitle: Text(_formatTimeRange(_activeSession!['start_time'] as String, _activeSession!['end_time'] as String)),
                  trailing: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text('$_checkinsToday', style: Theme.of(context).textTheme.headlineSmall),
                      const Text('check-ins', style: TextStyle(fontSize: 11)),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
            ],
            if (_pendingPayments.isNotEmpty) ...[
              Text('Pending Cash Approvals (${_pendingPayments.length})', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              Card(
                child: Column(
                  children: _pendingPayments.map((row) {
                    final payment = row as Map<String, dynamic>;
                    final pendingId = payment['id'] as int;
                    final displayName = payment['display_name'] as String;
                    final resolving = _resolvingPaymentIds.contains(pendingId);
                    final typeLabel = payment['type'] == 'entrance_fee' ? 'Entrance Fee' : 'Renewal';
                    return ListTile(
                      title: Text(displayName),
                      subtitle: Text('$typeLabel — \$${payment['amount']} cash'),
                      trailing: resolving
                          ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2))
                          : Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                FilledButton(
                                  onPressed: () => _resolvePayment(pendingId, 'approve', displayName),
                                  child: const Text('Approve'),
                                ),
                                const SizedBox(width: 8),
                                OutlinedButton(
                                  onPressed: () => _resolvePayment(pendingId, 'deny', displayName),
                                  child: const Text('Deny'),
                                ),
                              ],
                            ),
                    );
                  }).toList(),
                ),
              ),
              const SizedBox(height: 24),
            ],
            Text('Quick Member Actions', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            TextField(
              controller: _searchController,
              onChanged: _onSearchChanged,
              decoration: InputDecoration(
                labelText: 'Search by name, email, or phone',
                suffixIcon: _searching ? const Padding(padding: EdgeInsets.all(12), child: CircularProgressIndicator(strokeWidth: 2)) : null,
              ),
            ),
            if (_searchResults.isNotEmpty) ...[
              const SizedBox(height: 12),
              Card(
                child: Column(
                  children: _searchResults.map((row) {
                    final contact = row as Map<String, dynamic>;
                    final contactId = contact['id'] as int;
                    final displayName = contact['display_name'] as String;
                    return ListTile(
                      title: Text(displayName),
                      subtitle: Text([
                        if (contact['email'] != null) contact['email'],
                        if (contact['phone'] != null) contact['phone'],
                      ].join(' · ')),
                      trailing: _checkingInContactId == contactId
                          ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2))
                          : Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                IconButton(
                                  icon: const Icon(Icons.person_outline),
                                  tooltip: 'View Profile',
                                  onPressed: () => Navigator.of(context).push(
                                    MaterialPageRoute(
                                      builder: (_) => MemberProfileScreen(authRepository: widget.authRepository, contactId: contactId),
                                    ),
                                  ),
                                ),
                                FilledButton(
                                  onPressed: () => _openCheckInConfirm(contactId, displayName),
                                  child: const Text('Check In'),
                                ),
                              ],
                            ),
                    );
                  }).toList(),
                ),
              ),
            ],
            const SizedBox(height: 32),
            Text('Check-Ins Log', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            if (_checkinsLog.isEmpty && !_loadingDashboard)
              const Text('No check-ins yet today.')
            else
              Card(
                child: Column(
                  children: _checkinsLog.map((row) {
                    final checkin = row as Map<String, dynamic>;
                    final checkinId = checkin['checkin_id'] as int;
                    final displayName = checkin['display_name'] as String;
                    final guestName = checkin['guest_name'] as String?;
                    final timeLabel = _formatTime(checkin['checked_in_at'] as String);
                    // Guest check-ins are their own tgg_checkins row sharing
                    // the member's contact_id, not a separate contact -- lead
                    // with the guest's name so it doesn't read as a second
                    // "Lori checked in" entry.
                    return ListTile(
                      title: Text(guestName ?? displayName),
                      subtitle: guestName != null ? Text('Guest of: $displayName') : null,
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(timeLabel),
                          _deletingCheckinId == checkinId
                              ? const Padding(
                                  padding: EdgeInsets.only(left: 8),
                                  child: SizedBox(height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2)),
                                )
                              : IconButton(
                                  icon: Icon(Icons.delete_outline, color: Theme.of(context).colorScheme.error),
                                  tooltip: 'Delete check-in',
                                  onPressed: () => _confirmDeleteCheckin(checkinId, displayName),
                                ),
                        ],
                      ),
                    );
                  }).toList(),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Guest-pass confirmation dialog, mirroring host_checkin.php's
/// guest-confirm panel: looks up the selected member's remaining guest
/// passes for the month, then lets the host optionally add up to that many
/// guest names before confirming the check-in. Returns the chosen guest
/// names (possibly empty) on confirm, or null if cancelled.
class _GuestConfirmDialog extends StatefulWidget {
  final ApiClient api;
  final AuthRepository authRepository;
  final int contactId;
  final String displayName;

  const _GuestConfirmDialog({
    required this.api,
    required this.authRepository,
    required this.contactId,
    required this.displayName,
  });

  @override
  State<_GuestConfirmDialog> createState() => _GuestConfirmDialogState();
}

class _GuestConfirmDialogState extends State<_GuestConfirmDialog> {
  bool _loading = true;
  int _remaining = 0;
  bool _addingGuests = false;
  final List<TextEditingController> _controllers = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final controller in _controllers) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    final result = await widget.authRepository.authedCall((token) => widget.api.hostGuestPasses(token, widget.contactId));
    if (!mounted) return;
    setState(() {
      _loading = false;
      _remaining = (result['remaining'] as int?) ?? 0;
    });
  }

  void _addField() {
    if (_controllers.length >= _remaining) return;
    setState(() => _controllers.add(TextEditingController()));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Checking in ${widget.displayName}'),
      content: _loading
          ? const SizedBox(height: 60, child: Center(child: CircularProgressIndicator()))
          : Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (_remaining > 0) ...[
                  Text(
                    '$_remaining guest pass${_remaining == 1 ? '' : 'es'} available this month',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    icon: const Icon(Icons.person_add_alt_outlined),
                    label: Text(_addingGuests ? 'Adding guest(s)' : 'Add guest(s)?'),
                    onPressed: () => setState(() {
                      _addingGuests = !_addingGuests;
                      if (_addingGuests && _controllers.isEmpty) _addField();
                    }),
                  ),
                  if (_addingGuests) ...[
                    const SizedBox(height: 8),
                    for (final controller in _controllers)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: TextField(controller: controller, decoration: const InputDecoration(labelText: "Guest's name")),
                      ),
                    if (_controllers.length < _remaining)
                      TextButton(onPressed: _addField, child: const Text('+ Add another guest')),
                  ],
                ] else
                  const Text('No guest passes remaining this month.'),
              ],
            ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        FilledButton(
          onPressed: _loading
              ? null
              : () => Navigator.of(context).pop(
                    _addingGuests ? _controllers.map((c) => c.text.trim()).where((n) => n.isNotEmpty).toList() : const <String>[],
                  ),
          child: const Text('Confirm Check-In'),
        ),
      ],
    );
  }
}
