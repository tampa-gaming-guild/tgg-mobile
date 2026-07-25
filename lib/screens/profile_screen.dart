import 'package:flutter/material.dart';

import '../api/api_client.dart';
import '../auth/auth_repository.dart';
import '../theme/theme_controller.dart';
import 'account_settings_screen.dart';
import 'attendance_history_screen.dart';
import 'credits_history_screen.dart';
import 'payment_history_screen.dart';

class ProfileScreen extends StatefulWidget {
  final AuthRepository authRepository;
  final ThemeController themeController;

  const ProfileScreen({super.key, required this.authRepository, required this.themeController});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
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

    final result = await widget.authRepository.authedCall(_api.getProfile);

    setState(() {
      _loading = false;
      if (result['statusCode'] == 200) {
        _profile = result;
      } else {
        _errorMessage = result['error'] as String? ?? 'Could not load your profile.';
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Profile'),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: 'Account Settings',
            onPressed: () async {
              await Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => AccountSettingsScreen(authRepository: widget.authRepository, themeController: widget.themeController),
                ),
              );
              _load(); // settings may have changed (display name, toggles, etc.)
            },
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: _buildBody(context),
      ),
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
        const SizedBox(height: 24),
        _SectionCard(
          title: 'Membership',
          child: membership == null
              ? const Text('No active membership on file.')
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('${membership['membership_name']} — ${membership['status_label']}'),
                    const SizedBox(height: 4),
                    Text('Joined ${_formatDate(membership['join_date'] as String)}'),
                    const SizedBox(height: 4),
                    Text('Expires ${_formatDate(membership['end_date'] as String)}'),
                  ],
                ),
        ),
        const SizedBox(height: 16),
        _SectionCard(
          title: 'Membership Credits',
          onViewAll: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => CreditsHistoryScreen(authRepository: widget.authRepository)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('${credits['available']} available'),
              Text('${credits['earned']} earned, ${credits['applied']} applied, ${credits['expired']} expired'),
              if (credits['next_expiration_date'] != null) ...[
                const SizedBox(height: 4),
                Text(
                  '${credits['next_expiration_credits']} expiring ${_formatDate(credits['next_expiration_date'] as String)}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
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
          onViewAll: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => AttendanceHistoryScreen(authRepository: widget.authRepository)),
          ),
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
                          Text(_formatDateTime(row['checked_in_at'] as String)),
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
          onViewAll: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => PaymentHistoryScreen(authRepository: widget.authRepository)),
          ),
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

  String _formatDateTime(String isoDateTime) {
    final date = DateTime.parse(isoDateTime);
    return '${_formatDate(isoDateTime)} ${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
  }
}

class _SectionCard extends StatelessWidget {
  final String title;
  final Widget child;
  final VoidCallback? onViewAll;

  const _SectionCard({required this.title, required this.child, this.onViewAll});

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(title, style: Theme.of(context).textTheme.titleMedium),
                if (onViewAll != null)
                  TextButton.icon(
                    onPressed: onViewAll,
                    label: const Text('View All'),
                    icon: const Icon(Icons.arrow_forward, size: 16),
                    iconAlignment: IconAlignment.end,
                  ),
              ],
            ),
            const SizedBox(height: 8),
            child,
          ],
        ),
      ),
    );
  }
}
