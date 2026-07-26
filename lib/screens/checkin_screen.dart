import 'package:flutter/material.dart';

import '../api/api_client.dart';
import '../auth/auth_repository.dart';
import 'payment_flow_screen.dart';

/// Self check-in tab, split out of what used to be on the member home
/// screen -- its own bottom-nav tab now, shown only while a check-in window
/// is open (see MainShell). Mirrors checkin.php's "bring a guest?" toggle:
/// hidden entirely when the member's plan has no guest-pass allowance,
/// otherwise lets them add up to their remaining monthly passes before
/// checking in.
class CheckInScreen extends StatefulWidget {
  final AuthRepository authRepository;

  const CheckInScreen({super.key, required this.authRepository});

  @override
  State<CheckInScreen> createState() => _CheckInScreenState();
}

class _CheckInScreenState extends State<CheckInScreen> {
  final _api = ApiClient();
  bool _checkingIn = false;
  String? _resultMessage;
  bool _resultIsError = false;

  int _guestPassesRemaining = 0;
  bool _bringingGuest = false;
  final List<TextEditingController> _guestControllers = [];

  @override
  void initState() {
    super.initState();
    _loadGuestPasses();
  }

  @override
  void dispose() {
    for (final controller in _guestControllers) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _loadGuestPasses() async {
    final result = await widget.authRepository.authedCall(_api.guestPasses);
    if (!mounted) return;
    setState(() => _guestPassesRemaining = (result['remaining'] as int?) ?? 0);
  }

  void _addGuestField() {
    if (_guestControllers.length >= _guestPassesRemaining) return;
    setState(() => _guestControllers.add(TextEditingController()));
  }

  Future<void> _checkIn() async {
    final guestNames = _bringingGuest
        ? _guestControllers.map((c) => c.text.trim()).where((name) => name.isNotEmpty).toList()
        : const <String>[];

    setState(() {
      _checkingIn = true;
      _resultMessage = null;
    });

    final result = await widget.authRepository.authedCall((token) => _api.checkIn(token, guestNames: guestNames));

    if (!mounted) return;
    setState(() {
      _checkingIn = false;
      if (result['success'] == true) {
        _resultIsError = false;
        _resultMessage = result['message'] as String? ?? 'Checked in!';
        _bringingGuest = false;
        for (final controller in _guestControllers) {
          controller.dispose();
        }
        _guestControllers.clear();
        _loadGuestPasses(); // this month's remaining count just changed
      } else if (result['redirect_reason'] != null) {
        _resultIsError = false;
        _resultMessage = null;
        _openPaymentFlow(result['redirect_reason'] as String);
      } else {
        _resultIsError = true;
        _resultMessage = result['error'] as String? ?? 'Check-in failed.';
      }
    });
  }

  /// Opens the native Card/Cash (+ tier picker) screen -- mirrors
  /// pay-entrance.php's flow, but the webview only ever shows for Stripe's
  /// own hosted Checkout page inside it, not this picker itself. A
  /// successful card payment there also completes the check-in itself
  /// (the backend inserts the tgg_checkins row), so there's nothing further
  /// to call here on success.
  Future<void> _openPaymentFlow(String reason) async {
    final displayName = widget.authRepository.user?['display_name'] as String? ?? 'you';
    final outcome = await Navigator.of(context).push<String>(
      MaterialPageRoute(
        builder: (_) => PaymentFlowScreen(
          authRepository: widget.authRepository,
          displayName: displayName,
          initialReason: reason,
        ),
      ),
    );
    if (!mounted) return;

    setState(() {
      if (outcome == 'success') {
        _resultIsError = false;
        _resultMessage = "Payment complete -- you're checked in!";
      } else if (outcome == 'cash_pending') {
        _resultIsError = false;
        _resultMessage = 'See the Host to pay in cash. Your check-in will be completed once they confirm payment.';
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Check-In')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 400),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Icon(Icons.check_circle_outline, size: 64),
                const SizedBox(height: 16),
                Text(
                  "You're checking in for today's session.",
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                if (_guestPassesRemaining > 0) ...[
                  const SizedBox(height: 24),
                  OutlinedButton.icon(
                    icon: const Icon(Icons.person_add_alt_outlined),
                    label: Text(_bringingGuest ? 'Bringing a guest' : 'Bring a guest?'),
                    onPressed: () => setState(() {
                      _bringingGuest = !_bringingGuest;
                      if (_bringingGuest && _guestControllers.isEmpty) _addGuestField();
                    }),
                  ),
                  Text(
                    '$_guestPassesRemaining guest pass${_guestPassesRemaining == 1 ? '' : 'es'} available this month',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  if (_bringingGuest) ...[
                    const SizedBox(height: 12),
                    for (final controller in _guestControllers) ...[
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: TextField(
                          controller: controller,
                          decoration: const InputDecoration(labelText: "Guest's name"),
                        ),
                      ),
                    ],
                    if (_guestControllers.length < _guestPassesRemaining)
                      TextButton(onPressed: _addGuestField, child: const Text('+ Add another guest')),
                  ],
                ],
                const SizedBox(height: 24),
                FilledButton(
                  onPressed: _checkingIn ? null : _checkIn,
                  child: _checkingIn
                      ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Text('Check In'),
                ),
                if (_resultMessage != null) ...[
                  const SizedBox(height: 16),
                  Text(
                    _resultMessage!,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: _resultIsError ? Theme.of(context).colorScheme.error : Colors.green,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
