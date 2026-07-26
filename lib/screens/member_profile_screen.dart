import 'package:flutter/material.dart';

import '../api/api_client.dart';
import '../auth/auth_repository.dart';
import 'renew_membership_screen.dart';

/// Read-only view of another member's profile for a host, mirroring
/// profile.php's contact/membership/credits/attendance/payment sections --
/// reached from the Hosting tab's member search. No pagination (unlike the
/// member's own Home profile); a "Renew" button leads to the offline
/// renewal form.
class MemberProfileScreen extends StatefulWidget {
  final AuthRepository authRepository;
  final int contactId;

  const MemberProfileScreen({super.key, required this.authRepository, required this.contactId});

  @override
  State<MemberProfileScreen> createState() => _MemberProfileScreenState();
}

class _MemberProfileScreenState extends State<MemberProfileScreen> {
  final _api = ApiClient();
  bool _loading = true;
  String? _errorMessage;
  Map<String, dynamic>? _profile;

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

    final result = await widget.authRepository.authedCall((token) => _api.hostMemberProfile(token, widget.contactId));

    if (!mounted) return;
    setState(() {
      _loading = false;
      if (result['statusCode'] == 200) {
        _profile = result;
      } else {
        _errorMessage = result['error'] as String? ?? 'Could not load this member.';
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final displayName = (_profile?['contact'] as Map<String, dynamic>?)?['display_name'] as String?;
    return Scaffold(
      appBar: AppBar(title: Text(displayName ?? 'Member Profile')),
      body: RefreshIndicator(onRefresh: _load, child: _buildBody(context)),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (_loading && _profile == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_errorMessage != null && _profile == null) {
      return ListView(
        children: [
          const SizedBox(height: 80),
          Icon(Icons.error_outline, size: 48, color: Theme.of(context).colorScheme.error),
          const SizedBox(height: 12),
          Text(_errorMessage!, textAlign: TextAlign.center),
        ],
      );
    }

    final contact = _profile!['contact'] as Map<String, dynamic>;
    final membership = _profile!['membership'] as Map<String, dynamic>?;
    final credits = _profile!['credits'] as Map<String, dynamic>;
    final creditGrants = (_profile!['credit_grants'] as List<dynamic>).cast<Map<String, dynamic>>();
    final attendance = (_profile!['recent_attendance'] as List<dynamic>).cast<Map<String, dynamic>>();
    final paymentHistory = (_profile!['payment_history'] as List<dynamic>).cast<Map<String, dynamic>>();

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(contact['display_name'] as String, style: Theme.of(context).textTheme.headlineSmall),
        Text(contact['email'] as String, style: Theme.of(context).textTheme.bodySmall),
        if (contact['phone'] != null) Text(contact['phone'] as String, style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: 24),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text('Membership', style: Theme.of(context).textTheme.titleMedium),
                    FilledButton(
                      onPressed: () async {
                        final renewed = await Navigator.of(context).push<bool>(
                          MaterialPageRoute(
                            builder: (_) => RenewMembershipScreen(
                              authRepository: widget.authRepository,
                              contactId: widget.contactId,
                              displayName: contact['display_name'] as String,
                              membership: membership,
                              hasCardOnFile: _profile!['has_card_on_file'] == true,
                            ),
                          ),
                        );
                        if (renewed == true) _load();
                      },
                      child: const Text('Renew'),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                if (membership == null)
                  const Text('No active membership on file.')
                else ...[
                  Text('${membership['membership_name']} — ${membership['status_label']}'),
                  const SizedBox(height: 4),
                  Text('Joined ${_formatDate(membership['join_date'] as String)}'),
                  const SizedBox(height: 4),
                  Text('Expires ${_formatDate(membership['end_date'] as String)}'),
                ],
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        _SectionCard(
          title: 'Membership Credits',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('${credits['available']} available'),
              Text('${credits['earned']} earned, ${credits['applied']} applied, ${credits['expired']} expired'),
              if (creditGrants.isNotEmpty) ...[
                const Divider(height: 20),
                ...creditGrants.map((grant) {
                  final remaining = grant['remaining'] as int;
                  final granted = grant['granted'] as int;
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 3),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Expanded(child: Text('${_formatDate(grant['date'] as String)} — ${grant['shift']}')),
                        Text('$remaining / $granted', style: Theme.of(context).textTheme.bodySmall),
                      ],
                    ),
                  );
                }),
              ],
            ],
          ),
        ),
        const SizedBox(height: 16),
        _SectionCard(
          title: 'Recent Attendance',
          child: attendance.isEmpty
              ? const Text('No check-ins on file yet.')
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: attendance.map((row) {
                    final guestName = row['guest_name'] as String?;
                    final label = guestName != null ? 'Guest: $guestName' : (row['notes'] as String? ?? 'Visit');
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(_formatDate(row['checked_in_at'] as String)),
                          Flexible(child: Text(label, textAlign: TextAlign.end)),
                        ],
                      ),
                    );
                  }).toList(),
                ),
        ),
        const SizedBox(height: 16),
        _SectionCard(
          title: 'Payment History',
          child: paymentHistory.isEmpty
              ? const Text('No billing transactions found.')
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: paymentHistory.map((row) {
                    final amount = double.tryParse(row['amount'].toString()) ?? 0;
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Expanded(child: Text('${_formatDate(row['created_at'] as String)} — ${row['plan_name']}')),
                          Text('\$${amount.toStringAsFixed(2)}'),
                        ],
                      ),
                    );
                  }).toList(),
                ),
        ),
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

class _SectionCard extends StatelessWidget {
  final String title;
  final Widget child;

  const _SectionCard({required this.title, required this.child});

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            child,
          ],
        ),
      ),
    );
  }
}
