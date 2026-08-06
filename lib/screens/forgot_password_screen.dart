import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api/api_client.dart';

/// Logged-out "forgot password" flow, reached from LoginScreen. Two steps in
/// one screen (no router in this app, so no separate route): request a code
/// by email, then enter that code plus a new password in a single call --
/// see ApiClient.resetPassword for why there's no intermediate token step.
class ForgotPasswordScreen extends StatefulWidget {
  const ForgotPasswordScreen({super.key});

  @override
  State<ForgotPasswordScreen> createState() => _ForgotPasswordScreenState();
}

class _ForgotPasswordScreenState extends State<ForgotPasswordScreen> {
  final _api = ApiClient();

  final _emailController = TextEditingController();
  final _codeController = TextEditingController();
  final _newPasswordController = TextEditingController();
  final _confirmPasswordController = TextEditingController();

  bool _codeSent = false;
  bool _submitting = false;
  String? _requestError;
  String? _resetError;

  @override
  void dispose() {
    _emailController.dispose();
    _codeController.dispose();
    _newPasswordController.dispose();
    _confirmPasswordController.dispose();
    super.dispose();
  }

  Future<void> _sendCode() async {
    final email = _emailController.text.trim();
    if (email.isEmpty) {
      setState(() => _requestError = 'Please enter your email address.');
      return;
    }

    setState(() {
      _submitting = true;
      _requestError = null;
    });

    Map<String, dynamic> result;
    try {
      result = await _api.forgotPassword(email);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _requestError = 'Could not reach the server. Check your connection and try again.';
      });
      return;
    }

    if (!mounted) return;
    setState(() {
      _submitting = false;
      if (result['success'] == true) {
        _codeSent = true;
      } else {
        _requestError = result['error'] as String? ?? 'Something went wrong. Please try again.';
      }
    });
  }

  Future<void> _resetPassword() async {
    final code = _codeController.text.trim();
    final newPassword = _newPasswordController.text;
    final confirmPassword = _confirmPasswordController.text;

    if (code.isEmpty || newPassword.isEmpty || confirmPassword.isEmpty) {
      setState(() => _resetError = 'Please fill in all fields.');
      return;
    }
    if (newPassword != confirmPassword) {
      setState(() => _resetError = 'Passwords do not match.');
      return;
    }

    setState(() {
      _submitting = true;
      _resetError = null;
    });

    Map<String, dynamic> result;
    try {
      result = await _api.resetPassword(email: _emailController.text.trim(), code: code, newPassword: newPassword);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _resetError = 'Could not reach the server. Check your connection and try again.';
      });
      return;
    }

    if (!mounted) return;

    if (result['success'] == true) {
      final messenger = ScaffoldMessenger.of(context);
      Navigator.of(context).pop();
      messenger.showSnackBar(const SnackBar(content: Text('Password reset. Please sign in with your new password.')));
    } else {
      setState(() {
        _submitting = false;
        _resetError = result['error'] as String? ?? 'Could not reset your password.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Forgot Password')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 400),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: _codeSent ? _buildResetStep(context) : _buildRequestStep(context),
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _buildRequestStep(BuildContext context) {
    return [
      const Text('Enter your account email and we\'ll send you a 6-digit reset code.'),
      const SizedBox(height: 20),
      TextField(
        controller: _emailController,
        keyboardType: TextInputType.emailAddress,
        autocorrect: false,
        autofocus: true,
        decoration: const InputDecoration(labelText: 'Email'),
        onSubmitted: (_) => _submitting ? null : _sendCode(),
      ),
      const SizedBox(height: 20),
      if (_requestError != null) ...[
        Text(_requestError!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
        const SizedBox(height: 12),
      ],
      FilledButton(
        onPressed: _submitting ? null : _sendCode,
        child: _submitting
            ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2))
            : const Text('Send Code'),
      ),
    ];
  }

  List<Widget> _buildResetStep(BuildContext context) {
    return [
      const Text('If that email is registered, we\'ve sent a reset code. Enter it below with your new password.'),
      const SizedBox(height: 20),
      TextField(
        controller: _codeController,
        keyboardType: TextInputType.number,
        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
        maxLength: 6,
        autofocus: true,
        decoration: const InputDecoration(labelText: 'Reset Code', counterText: ''),
      ),
      const SizedBox(height: 12),
      TextField(
        controller: _newPasswordController,
        obscureText: true,
        autofillHints: const [AutofillHints.newPassword],
        decoration: const InputDecoration(labelText: 'New Password'),
      ),
      const SizedBox(height: 12),
      TextField(
        controller: _confirmPasswordController,
        obscureText: true,
        autofillHints: const [AutofillHints.newPassword],
        decoration: const InputDecoration(labelText: 'Confirm New Password'),
        onSubmitted: (_) => _submitting ? null : _resetPassword(),
      ),
      const SizedBox(height: 20),
      if (_resetError != null) ...[
        Text(_resetError!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
        const SizedBox(height: 12),
      ],
      FilledButton(
        onPressed: _submitting ? null : _resetPassword,
        child: _submitting
            ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2))
            : const Text('Reset Password'),
      ),
      const SizedBox(height: 12),
      TextButton(
        onPressed: _submitting ? null : _sendCode,
        child: const Text('Resend code'),
      ),
    ];
  }
}
