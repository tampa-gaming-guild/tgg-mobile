import 'package:flutter/material.dart';

import '../api/api_client.dart';
import '../auth/auth_repository.dart';

/// Volunteer signup tab, mirroring volunteers.php's "Upcoming" list view:
/// every scheduled event from today forward with its volunteer slots, open
/// ones tappable to sign up, the caller's own filled ones cancellable.
/// Mobile-only scope: no "sign up for all slots" bulk action and no
/// assigning another member -- self-service signup/cancel only.
class VolunteerScreen extends StatefulWidget {
  final AuthRepository authRepository;

  const VolunteerScreen({super.key, required this.authRepository});

  @override
  State<VolunteerScreen> createState() => _VolunteerScreenState();
}

class _VolunteerScreenState extends State<VolunteerScreen> {
  final _api = ApiClient();
  bool _loading = true;
  String? _errorMessage;
  List<dynamic> _events = const [];
  int? _pendingSlotId;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _errorMessage = null;
    });

    final result = await widget.authRepository.authedCall(_api.volunteerSchedule);

    setState(() {
      _loading = false;
      if (result['statusCode'] == 200) {
        _events = (result['events'] as List<dynamic>?) ?? const [];
      } else {
        _errorMessage = result['error'] as String? ?? 'Could not load the volunteer schedule.';
      }
    });
  }

  Future<void> _signUp(int slotId, String slotLabel) async {
    setState(() => _pendingSlotId = slotId);
    final result = await widget.authRepository.authedCall((token) => _api.volunteerSignup(token, slotId));
    if (!mounted) return;
    setState(() => _pendingSlotId = null);

    final ok = result['success'] == true;
    _showSnack(ok ? (result['message'] as String? ?? 'Signed up.') : (result['error'] as String? ?? 'Could not sign up for this slot.'), isError: !ok);
    if (ok) await _load();
  }

  Future<void> _cancel(int slotId, String slotLabel) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Cancel Signup?'),
        content: Text('Remove yourself from the $slotLabel volunteer slot?'),
        actions: [
          TextButton(onPressed: () => Navigator.of(dialogContext).pop(false), child: const Text('Keep It')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.error),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Cancel Signup'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    setState(() => _pendingSlotId = slotId);
    final result = await widget.authRepository.authedCall((token) => _api.volunteerCancel(token, slotId));
    if (!mounted) return;
    setState(() => _pendingSlotId = null);

    final ok = result['success'] == true;
    _showSnack(ok ? (result['message'] as String? ?? 'Signup cancelled.') : (result['error'] as String? ?? 'Could not cancel this signup.'), isError: !ok);
    if (ok) await _load();
  }

  void _showSnack(String message, {bool isError = false}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: isError ? Theme.of(context).colorScheme.error : null),
    );
  }

  String _formatEventHeader(String startIso, String endIso) {
    final start = DateTime.parse(startIso);
    final end = DateTime.parse(endIso);
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec', //
    ];
    final date = '${months[start.month - 1]} ${start.day}, ${start.year}';
    return '$date — ${_formatTime(start)} to ${_formatTime(end)}';
  }

  String _formatTime(DateTime dt) {
    final hour12 = dt.hour % 12 == 0 ? 12 : dt.hour % 12;
    final minute = dt.minute.toString().padLeft(2, '0');
    final period = dt.hour < 12 ? 'AM' : 'PM';
    return '$hour12:$minute $period';
  }

  Color _slotColor(BuildContext context, String slotType) {
    return switch (slotType) {
      'close' => Theme.of(context).colorScheme.error,
      'greeter' => Theme.of(context).colorScheme.primary,
      _ => Colors.green,
    };
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Volunteer Schedule')),
      body: RefreshIndicator(
        onRefresh: _load,
        child: _buildBody(context),
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (_loading && _events.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_errorMessage != null && _events.isEmpty) {
      return ListView(
        children: [
          const SizedBox(height: 80),
          Icon(Icons.error_outline, size: 48, color: Theme.of(context).colorScheme.error),
          const SizedBox(height: 12),
          Text(_errorMessage!, textAlign: TextAlign.center),
        ],
      );
    }
    if (_events.isEmpty) {
      return ListView(
        children: const [
          SizedBox(height: 80),
          Center(child: Text('No upcoming events scheduled.')),
        ],
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: _events.length,
      itemBuilder: (context, index) {
        final event = _events[index] as Map<String, dynamic>;
        final slots = (event['slots'] as List<dynamic>).cast<Map<String, dynamic>>();

        return Card(
          margin: const EdgeInsets.only(bottom: 16),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(event['title'] as String, style: Theme.of(context).textTheme.titleMedium),
                Text(
                  _formatEventHeader(event['start_time'] as String, event['end_time'] as String),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 12),
                ...slots.map((slot) {
                  final slotId = slot['id'] as int;
                  final slotLabel = slot['slot_label'] as String;
                  final filled = slot['filled'] == true;
                  final isSelf = slot['is_self'] == true;
                  final isPending = slot['status'] == 'pending';
                  final busy = _pendingSlotId == slotId;
                  final color = _slotColor(context, slot['slot_type'] as String);

                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(
                      children: [
                        Icon(Icons.circle, size: 10, color: filled ? color : color.withValues(alpha: 0.3)),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            filled
                                ? '$slotLabel — ${slot['volunteer_name']}${isPending ? ' (pending)' : ''}'
                                : '$slotLabel — open',
                          ),
                        ),
                        if (busy)
                          const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2))
                        else if (!filled)
                          FilledButton(
                            style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 12)),
                            onPressed: () => _signUp(slotId, slotLabel),
                            child: const Text('Sign Up'),
                          )
                        else if (isSelf)
                          OutlinedButton(
                            style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 12)),
                            onPressed: () => _cancel(slotId, slotLabel),
                            child: const Text('Cancel'),
                          ),
                      ],
                    ),
                  );
                }),
              ],
            ),
          ),
        );
      },
    );
  }
}
