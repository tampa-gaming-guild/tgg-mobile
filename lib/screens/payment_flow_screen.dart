import 'package:flutter/material.dart';

import '../api/api_client.dart';
import '../auth/auth_repository.dart';
import 'payment_webview_screen.dart';

/// Native Card/Cash (+ tier picker, for a renewal) screen for a check-in
/// that's blocked on payment -- entrance fee owed, or membership expired.
/// Mirrors pay-entrance.php's flow, but as proper native UI: the webview is
/// only ever shown for the actual Stripe Checkout page, not this picker.
///
/// [contactId] is null for self-service check-in (the caller's own payment)
/// or set when a host is checking someone else in -- same screen either
/// way, just different backend endpoints under the hood (see ApiClient's
/// paymentContext/paymentCheckoutSession/paymentCash).
///
/// Pops with 'success' (paid/checked in), 'cash_pending' (awaiting host
/// approval), or null (backed out without paying).
class PaymentFlowScreen extends StatefulWidget {
  final AuthRepository authRepository;
  final String displayName;
  final String initialReason; // 'entrance_fee' | 'renewal'
  final int? contactId;

  const PaymentFlowScreen({
    super.key,
    required this.authRepository,
    required this.displayName,
    required this.initialReason,
    this.contactId,
  });

  bool get isHost => contactId != null;

  @override
  State<PaymentFlowScreen> createState() => _PaymentFlowScreenState();
}

class _PaymentFlowScreenState extends State<PaymentFlowScreen> {
  final _api = ApiClient();

  bool _loading = true;
  String? _loadError;
  bool _hasPendingPayment = false;

  late String _reason; // can pivot from 'renewal' to 'entrance_fee'
  double? _amount;
  String? _membershipName;
  List<dynamic> _tiers = const [];
  int? _selectedTierId;

  bool _submitting = false;

  @override
  void initState() {
    super.initState();
    _reason = widget.initialReason;
    _loadContext();
  }

  Future<void> _loadContext() async {
    setState(() {
      _loading = true;
      _loadError = null;
    });

    final result = await widget.authRepository.authedCall(
      (token) => _api.paymentContext(token, reason: _reason, contactId: widget.contactId),
    );
    if (!mounted) return;

    setState(() {
      _loading = false;
      if (result['statusCode'] != 200) {
        _loadError = result['error'] as String? ?? 'Could not load payment details.';
        return;
      }
      _hasPendingPayment = result['has_pending_payment'] == true;
      if (_hasPendingPayment) return;

      if (_reason == 'entrance_fee') {
        _amount = (result['amount'] as num).toDouble();
        _membershipName = result['membership_name'] as String;
      } else {
        _tiers = (result['tiers'] as List<dynamic>?) ?? const [];
        final currentTierId = result['current_tier_id'] as int?;
        if (currentTierId != null && _tiers.any((t) => (t as Map<String, dynamic>)['id'] == currentTierId)) {
          _selectedTierId = currentTierId;
        } else if (_tiers.isNotEmpty) {
          _selectedTierId = (_tiers.first as Map<String, dynamic>)['id'] as int;
        }
      }
    });
  }

  void _applyPivot(Map<String, dynamic> result) {
    setState(() {
      _reason = 'entrance_fee';
      _amount = (result['amount'] as num).toDouble();
      _membershipName = result['membership_name'] as String;
      _tiers = const [];
      _selectedTierId = null;
    });
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('$_membershipName activated for free. Today\'s entrance fee of \$${_amount!.toStringAsFixed(2)} is still owed.'),
    ));
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: Theme.of(context).colorScheme.error),
    );
  }

  Future<void> _payCard() async {
    if (_reason == 'renewal' && _selectedTierId == null) return;

    setState(() => _submitting = true);
    final result = await widget.authRepository.authedCall(
      (token) => _api.paymentCheckoutSession(token, reason: _reason, tierId: _selectedTierId, contactId: widget.contactId),
    );
    if (!mounted) return;
    setState(() => _submitting = false);

    if (result['statusCode'] != 200) {
      _showError(result['error'] as String? ?? 'Could not start card checkout.');
      return;
    }
    if (result['pivoted_to_entrance_fee'] == true) {
      _applyPivot(result);
      return;
    }

    final outcome = await Navigator.of(context).push<String>(
      MaterialPageRoute(
        builder: (_) => PaymentWebViewScreen(
          title: _reason == 'entrance_fee' ? 'Entrance Fee' : 'Membership Renewal',
          initialUrl: result['checkout_url'] as String,
          // pay-entrance.php's success handling needs no PHP session for a
          // real check-in-flow request (this app never has a web session at
          // all), so it always lands on its own status=success URL -- unlike
          // renew.php there's no separate no-session-fallback redirect to
          // recognize here.
          terminalMarkers: const ['status=success', 'status=cancelled'],
        ),
      ),
    );
    if (!mounted) return;

    if (outcome == 'status=success') {
      Navigator.of(context).pop('success');
    } else if (outcome == 'status=cancelled') {
      _showError('Payment was cancelled.');
    }
  }

  Future<void> _payCash() async {
    if (_reason == 'renewal' && _selectedTierId == null) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Confirm Cash Payment'),
        content: Text(widget.isHost
            ? 'Record that ${widget.displayName} will pay \$${(_amount ?? 0).toStringAsFixed(2)} in cash? This goes on the pending-approval list until confirmed.'
            : 'Request to pay \$${(_amount ?? 0).toStringAsFixed(2)} in cash? The host will need to confirm it before your check-in completes.'),
        actions: [
          TextButton(onPressed: () => Navigator.of(dialogContext).pop(false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.of(dialogContext).pop(true), child: const Text('Confirm')),
        ],
      ),
    );
    if (confirmed != true) return;

    setState(() => _submitting = true);
    final result = await widget.authRepository.authedCall(
      (token) => _api.paymentCash(token, reason: _reason, tierId: _selectedTierId, contactId: widget.contactId),
    );
    if (!mounted) return;
    setState(() => _submitting = false);

    if (result['success'] != true) {
      _showError(result['error'] as String? ?? 'Could not record cash payment.');
      return;
    }
    if (result['pivoted_to_entrance_fee'] == true) {
      _applyPivot(result);
      return;
    }

    Navigator.of(context).pop('cash_pending');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(_reason == 'entrance_fee' ? 'Entrance Fee' : 'Membership Renewal')),
      body: _buildBody(context),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_loadError != null) {
      return Center(child: Padding(padding: const EdgeInsets.all(24), child: Text(_loadError!, textAlign: TextAlign.center)));
    }
    if (_hasPendingPayment) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            widget.isHost
                ? '${widget.displayName} already has a pending cash payment -- approve it from the Hosting Dashboard.'
                : 'You already have a pending payment with the host.',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(widget.displayName, style: Theme.of(context).textTheme.titleMedium, textAlign: TextAlign.center),
        const SizedBox(height: 8),
        if (_reason == 'entrance_fee') ...[
          Text(
            '\$${_amount!.toStringAsFixed(2)}',
            style: Theme.of(context).textTheme.headlineMedium,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 4),
          const Text('Entrance fee for today\'s visit.', textAlign: TextAlign.center),
        ] else ...[
          const Text('Membership has expired -- select a level to renew.', textAlign: TextAlign.center),
          const SizedBox(height: 16),
          DropdownButtonFormField<int>(
            initialValue: _selectedTierId,
            decoration: const InputDecoration(labelText: 'Membership Level'),
            items: _tiers.map((t) {
              final tier = t as Map<String, dynamic>;
              final isSession = tier['is_session'] == true;
              return DropdownMenuItem(
                value: tier['id'] as int,
                child: Text('${tier['name']} — ${isSession ? 'free to join, pay per visit' : '\$${(tier['minimum_fee'] as num).toStringAsFixed(2)}'}'),
              );
            }).toList(),
            onChanged: (v) => setState(() => _selectedTierId = v),
          ),
        ],
        const SizedBox(height: 32),
        FilledButton.icon(
          icon: const Icon(Icons.credit_card),
          label: const Text('Pay with Card'),
          onPressed: _submitting ? null : _payCard,
        ),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          icon: const Icon(Icons.payments_outlined),
          label: const Text('Pay Cash'),
          onPressed: _submitting ? null : _payCash,
        ),
        if (_submitting) ...[
          const SizedBox(height: 24),
          const Center(child: CircularProgressIndicator()),
        ],
      ],
    );
  }
}
