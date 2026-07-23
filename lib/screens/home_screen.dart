import 'package:flutter/material.dart';

import '../api/api_client.dart';
import '../auth/auth_repository.dart';
import 'profile_screen.dart';

class HomeScreen extends StatefulWidget {
  final AuthRepository authRepository;

  const HomeScreen({super.key, required this.authRepository});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _api = ApiClient();
  bool _checkingIn = false;
  String? _checkinResultMessage;
  bool _checkinResultIsError = false;

  List<String> get _roles => (widget.authRepository.user?['roles'] as List<dynamic>?)?.cast<String>() ?? const [];

  Future<void> _checkIn() async {
    setState(() {
      _checkingIn = true;
      _checkinResultMessage = null;
    });

    final result = await widget.authRepository.authedCall(_api.checkIn);

    setState(() {
      _checkingIn = false;
      if (result['success'] == true) {
        _checkinResultIsError = false;
        _checkinResultMessage = result['message'] as String? ?? 'Checked in!';
      } else if (result['redirect_reason'] != null) {
        _checkinResultIsError = true;
        _checkinResultMessage = result['redirect_reason'] == 'entrance_fee'
            ? 'An entrance fee is due before you can check in -- please see the host.'
            : 'Your membership needs to be renewed before you can check in.';
      } else {
        _checkinResultIsError = true;
        _checkinResultMessage = result['error'] as String? ?? 'Check-in failed.';
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final displayName = widget.authRepository.user?['display_name'] as String? ?? 'Member';

    return Scaffold(
      appBar: AppBar(
        title: const Text('TGG'),
        actions: [
          IconButton(
            icon: const Icon(Icons.person_outline),
            tooltip: 'Profile',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => ProfileScreen(authRepository: widget.authRepository)),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.logout),
            tooltip: 'Log out',
            onPressed: () => widget.authRepository.logout(),
          ),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 400),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('Welcome, $displayName', style: Theme.of(context).textTheme.headlineSmall),
                if (_roles.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(_roles.join(', '), style: Theme.of(context).textTheme.bodySmall),
                ],
                const SizedBox(height: 32),
                FilledButton(
                  onPressed: _checkingIn ? null : _checkIn,
                  child: _checkingIn
                      ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Text('Check In'),
                ),
                if (_checkinResultMessage != null) ...[
                  const SizedBox(height: 16),
                  Text(
                    _checkinResultMessage!,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: _checkinResultIsError ? Theme.of(context).colorScheme.error : Colors.green,
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
