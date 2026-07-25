import 'dart:async';

import 'package:flutter/material.dart';

import '../api/api_client.dart';
import '../auth/auth_repository.dart';

/// The Hosting tab, mirroring index.php's Hosting View: session banner,
/// today's check-in count, pending cash approvals, quick member search +
/// check-in, and the check-ins log. Only shown in the bottom nav while a
/// session is active and the caller holds 'edit checkins' (see MainShell),
/// and it's the default tab in that case.
class HostScreen extends StatefulWidget {
  final AuthRepository authRepository;

  const HostScreen({super.key, required this.authRepository});

  @override
  State<HostScreen> createState() => _HostScreenState();
}

class _HostScreenState extends State<HostScreen> {
  final _api = ApiClient();
  final _searchController = TextEditingController();
  Timer? _debounce;

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

  @override
  void initState() {
    super.initState();
    _loadDashboard();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadDashboard() async {
    setState(() {
      _loadingDashboard = true;
      _dashboardError = null;
    });

    final result = await widget.authRepository.authedCall(_api.hostDashboard);

    setState(() {
      _loadingDashboard = false;
      if (result['statusCode'] != 200) {
        _dashboardError = result['error'] as String? ?? 'Could not load the hosting dashboard.';
        return;
      }
      _isHostingNow = result['is_hosting_now'] == true;
      _activeSession = result['active_session'] as Map<String, dynamic>?;
      _checkinsToday = (result['checkins_today'] as int?) ?? 0;
      _pendingPayments = (result['pending_payments'] as List<dynamic>?) ?? const [];
      _checkinsLog = (result['checkins_log'] as List<dynamic>?) ?? const [];
    });
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

  // No confirmation dialog: a host mis-tap is one delete-checkin away from
  // undone, and search results (fewer than 15, name/email/phone match) are
  // specific enough that an extra tap-to-confirm is just friction.
  Future<void> _checkIn(int contactId, String displayName) async {
    setState(() => _checkingInContactId = contactId);
    final result = await widget.authRepository.authedCall((token) => _api.hostCheckIn(token, contactId));
    if (!mounted) return;
    setState(() => _checkingInContactId = null);

    final ok = result['success'] == true;
    String message;
    if (ok) {
      // Not result['message'] -- that's worded for self-check-in ("Welcome,
      // X!"), which reads backwards on the host's own screen.
      message = '$displayName checked in successfully.';
    } else if (result['redirect_reason'] != null) {
      message = result['redirect_reason'] == 'entrance_fee'
          ? '$displayName owes an entrance fee -- collect payment before checking in.'
          : "$displayName's membership needs to be renewed before checking in.";
    } else {
      message = result['error'] as String? ?? 'Check-in failed.';
    }

    _showSnack(message, isError: !ok);

    if (ok) {
      _searchController.clear();
      setState(() => _searchResults = const []);
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
                          : FilledButton(
                              onPressed: () => _checkIn(contactId, displayName),
                              child: const Text('Check In'),
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
                    return ListTile(
                      title: Text(displayName),
                      subtitle: guestName != null ? Text('Guest: $guestName') : null,
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
