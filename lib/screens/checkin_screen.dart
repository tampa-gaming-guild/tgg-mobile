import 'package:flutter/material.dart';

import '../api/api_client.dart';
import '../auth/auth_repository.dart';

/// Self check-in tab, split out of what used to be on the member home
/// screen -- its own bottom-nav tab now, shown only while a check-in window
/// is open (see MainShell).
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

  Future<void> _checkIn() async {
    setState(() {
      _checkingIn = true;
      _resultMessage = null;
    });

    final result = await widget.authRepository.authedCall(_api.checkIn);

    setState(() {
      _checkingIn = false;
      if (result['success'] == true) {
        _resultIsError = false;
        _resultMessage = result['message'] as String? ?? 'Checked in!';
      } else if (result['redirect_reason'] != null) {
        _resultIsError = true;
        _resultMessage = result['redirect_reason'] == 'entrance_fee'
            ? 'An entrance fee is due before you can check in -- please see the host.'
            : 'Your membership needs to be renewed before you can check in.';
      } else {
        _resultIsError = true;
        _resultMessage = result['error'] as String? ?? 'Check-in failed.';
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
          child: Padding(
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
                const SizedBox(height: 32),
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
