import 'package:flutter/material.dart';

import '../api/api_client.dart';
import '../auth/auth_repository.dart';
import 'payment_webview_screen.dart';

/// Renewal form, mirroring renew.php's simplified "Renew Membership"
/// section: pick a level, then either Charge Card on File (instant, only
/// shown when one exists), Pay with Card via Checkout (Stripe Checkout in
/// an in-app webview), or Pay Cash (host-confirmed on the spot, no pending
/// approval needed). Pops `true` on success so the caller
/// (MemberProfileScreen) knows to reload.
class RenewMembershipScreen extends StatefulWidget {
  final AuthRepository authRepository;
  final int contactId;
  final String displayName;
  final Map<String, dynamic>? membership;
  final bool hasCardOnFile;

  const RenewMembershipScreen({
    super.key,
    required this.authRepository,
    required this.contactId,
    required this.displayName,
    required this.membership,
    required this.hasCardOnFile,
  });

  @override
  State<RenewMembershipScreen> createState() => _RenewMembershipScreenState();
}

class _RenewMembershipScreenState extends State<RenewMembershipScreen> {
  final _api = ApiClient();

  bool _loadingPlans = true;
  String? _loadError;
  List<dynamic> _plans = const [];
  int? _selectedPlanId;
  bool _submitting = false;

  @override
  void initState() {
    super.initState();
    _loadPlans();
  }

  Future<void> _loadPlans() async {
    final result = await widget.authRepository.authedCall(_api.hostSubscriptionPlans);
    if (!mounted) return;

    setState(() {
      _loadingPlans = false;
      if (result['statusCode'] == 200) {
        _plans = (result['plans'] as List<dynamic>?) ?? const [];
        final currentPlanId = widget.membership?['membership_id'] as int?;
        if (currentPlanId != null && _plans.any((p) => (p as Map<String, dynamic>)['id'] == currentPlanId)) {
          _selectedPlanId = currentPlanId;
        } else if (_plans.isNotEmpty) {
          _selectedPlanId = (_plans.first as Map<String, dynamic>)['id'] as int;
        }
      } else {
        _loadError = result['error'] as String? ?? 'Could not load membership levels.';
      }
    });
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: Theme.of(context).colorScheme.error),
    );
  }

  Future<bool> _confirm(String message) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Confirm Renewal'),
        content: Text(message),
        actions: [
          TextButton(onPressed: () => Navigator.of(dialogContext).pop(false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.of(dialogContext).pop(true), child: const Text('Confirm')),
        ],
      ),
    );
    return confirmed == true;
  }

  Future<void> _payCardOnFile() async {
    if (_selectedPlanId == null) return;
    if (!await _confirm('Charge ${widget.displayName}\'s card on file for this renewal?')) return;

    setState(() => _submitting = true);
    final result = await widget.authRepository.authedCall(
      (token) => _api.hostRenew(token, contactId: widget.contactId, planId: _selectedPlanId!, paymentMethod: 'card_on_file'),
    );
    if (!mounted) return;
    setState(() => _submitting = false);

    if (result['success'] == true) {
      Navigator.of(context).pop(true);
    } else {
      _showError(result['error'] as String? ?? 'Card on file was declined.');
    }
  }

  Future<void> _payCash() async {
    if (_selectedPlanId == null) return;
    if (!await _confirm('Record a cash payment for ${widget.displayName}\'s renewal? This confirms payment was received.')) return;

    setState(() => _submitting = true);
    final result = await widget.authRepository.authedCall(
      (token) => _api.hostRenew(token, contactId: widget.contactId, planId: _selectedPlanId!, paymentMethod: 'cash'),
    );
    if (!mounted) return;
    setState(() => _submitting = false);

    if (result['success'] == true) {
      Navigator.of(context).pop(true);
    } else {
      _showError(result['error'] as String? ?? 'Failed to record cash renewal.');
    }
  }

  Future<void> _payViaCheckout() async {
    if (_selectedPlanId == null) return;

    setState(() => _submitting = true);
    final result = await widget.authRepository.authedCall(
      (token) => _api.hostCheckoutSession(token, contactId: widget.contactId, planId: _selectedPlanId!),
    );
    if (!mounted) return;
    setState(() => _submitting = false);

    if (result['statusCode'] != 200 || result['checkout_url'] == null) {
      _showError(result['error'] as String? ?? 'Could not start card checkout.');
      return;
    }

    final outcome = await Navigator.of(context).push<String>(
      MaterialPageRoute(
        builder: (_) => PaymentWebViewScreen(
          title: 'Pay with Card',
          initialUrl: result['checkout_url'] as String,
          // renew.php's success handler falls back to redirecting to
          // index.php?renew_success=1 when there's no PHP session to
          // continue into (true for this webview, Bearer-token only) --
          // that's the URL this in-app browser actually lands on, not the
          // intermediate renew.php?status=success one.
          terminalMarkers: const ['status=success', 'renew_success', 'status=cancelled'],
        ),
      ),
    );
    if (!mounted) return;

    if (outcome == 'status=success' || outcome == 'renew_success') {
      Navigator.of(context).pop(true);
    } else if (outcome == 'status=cancelled') {
      _showError('Payment was cancelled.');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Renew: ${widget.displayName}')),
      body: _loadingPlans
          ? const Center(child: CircularProgressIndicator())
          : _loadError != null
              ? Center(child: Text(_loadError!, textAlign: TextAlign.center))
              : _buildForm(context),
    );
  }

  Widget _buildForm(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (widget.membership != null) ...[
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Text('Current: ${widget.membership!['membership_name']}, expires ${_formatDate(widget.membership!['end_date'] as String)}'),
            ),
          ),
          const SizedBox(height: 16),
        ],
        DropdownButtonFormField<int>(
          initialValue: _selectedPlanId,
          decoration: const InputDecoration(labelText: 'Membership Level'),
          items: _plans.map((p) {
            final plan = p as Map<String, dynamic>;
            return DropdownMenuItem(
              value: plan['id'] as int,
              child: Text('${plan['name']} — \$${(plan['minimum_fee'] as num).toStringAsFixed(2)}'),
            );
          }).toList(),
          onChanged: (v) => setState(() => _selectedPlanId = v),
        ),
        const SizedBox(height: 24),
        if (widget.hasCardOnFile) ...[
          FilledButton.icon(
            icon: const Icon(Icons.credit_card),
            label: const Text('Charge Card on File'),
            onPressed: _submitting || _selectedPlanId == null ? null : _payCardOnFile,
          ),
          const SizedBox(height: 12),
        ],
        OutlinedButton.icon(
          icon: const Icon(Icons.open_in_browser),
          label: const Text('Pay with Card via Checkout'),
          onPressed: _submitting || _selectedPlanId == null ? null : _payViaCheckout,
        ),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          icon: const Icon(Icons.payments_outlined),
          label: const Text('Pay Cash'),
          onPressed: _submitting || _selectedPlanId == null ? null : _payCash,
        ),
        if (_submitting) ...[
          const SizedBox(height: 24),
          const Center(child: CircularProgressIndicator()),
        ],
      ],
    );
  }

  String _formatDate(String isoDate) {
    final date = DateTime.parse(isoDate);
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec', //
    ];
    return '${months[date.month - 1]} ${date.day}, ${date.year}';
  }
}
