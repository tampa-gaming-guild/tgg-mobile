import 'package:flutter/material.dart';

import '../api/api_client.dart';
import '../auth/auth_repository.dart';
import 'payment_webview_screen.dart';

/// Self-service renewal: pick a level, pay via Stripe Checkout in an in-app
/// webview. Card/Stripe only, by design -- Cash and Charge Card on File are
/// host-initiated-only options (see RenewMembershipScreen), not available
/// here. Pops `true` on success so the caller (ProfileScreen) knows to
/// reload.
class RenewScreen extends StatefulWidget {
  final AuthRepository authRepository;
  final Map<String, dynamic>? membership;

  const RenewScreen({super.key, required this.authRepository, required this.membership});

  @override
  State<RenewScreen> createState() => _RenewScreenState();
}

class _RenewScreenState extends State<RenewScreen> {
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
    final result = await widget.authRepository.authedCall(_api.subscriptionPlans);
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

  Future<void> _payViaCheckout() async {
    if (_selectedPlanId == null) return;

    setState(() => _submitting = true);
    final result = await widget.authRepository.authedCall((token) => _api.checkoutSession(token, planId: _selectedPlanId!));
    if (!mounted) return;
    setState(() => _submitting = false);

    if (result['statusCode'] != 200 || result['checkout_url'] == null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(result['error'] as String? ?? 'Could not start card checkout.'),
        backgroundColor: Theme.of(context).colorScheme.error,
      ));
      return;
    }

    final outcome = await Navigator.of(context).push<String>(
      MaterialPageRoute(
        builder: (_) => PaymentWebViewScreen(
          title: 'Renew Membership',
          initialUrl: result['checkout_url'] as String,
          // renew.php's success handler falls back to redirecting to
          // index.php?renew_success=1 when there's no PHP session to
          // continue into (true for this webview, which is Bearer-token
          // only) -- that's the URL this in-app browser actually lands on,
          // not the intermediate renew.php?status=success one, so it has to
          // be recognized as success too.
          terminalMarkers: const ['status=success', 'renew_success', 'status=cancelled'],
        ),
      ),
    );
    if (!mounted) return;

    if (outcome == 'status=success' || outcome == 'renew_success') {
      Navigator.of(context).pop(true);
    } else if (outcome == 'status=cancelled') {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Payment was cancelled.')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Renew Membership')),
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
        FilledButton.icon(
          icon: const Icon(Icons.credit_card),
          label: const Text('Pay with Card'),
          onPressed: _submitting || _selectedPlanId == null ? null : _payViaCheckout,
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
