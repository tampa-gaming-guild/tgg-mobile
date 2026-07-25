import 'package:flutter/material.dart';

import '../api/api_client.dart';
import '../auth/auth_repository.dart';

/// Full, pageable Membership Credit grant history behind the Home page's
/// 3-row teaser. Same infinite-scroll pattern as attendance/payment history.
class CreditsHistoryScreen extends StatefulWidget {
  final AuthRepository authRepository;

  const CreditsHistoryScreen({super.key, required this.authRepository});

  @override
  State<CreditsHistoryScreen> createState() => _CreditsHistoryScreenState();
}

class _CreditsHistoryScreenState extends State<CreditsHistoryScreen> {
  static const _pageSize = 20;

  final _api = ApiClient();
  final _scrollController = ScrollController();

  bool _initialLoading = true;
  bool _loadingMore = false;
  bool _hasMore = true;
  String? _errorMessage;
  final List<dynamic> _rows = [];

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    _loadMore();
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_hasMore || _loadingMore || _initialLoading) return;
    if (_scrollController.position.pixels >= _scrollController.position.maxScrollExtent - 200) {
      _loadMore();
    }
  }

  Future<void> _loadMore() async {
    setState(() {
      if (_rows.isEmpty) {
        _initialLoading = true;
      } else {
        _loadingMore = true;
      }
      _errorMessage = null;
    });

    final result = await widget.authRepository.authedCall(
      (token) => _api.creditsHistory(token, offset: _rows.length, limit: _pageSize),
    );

    if (!mounted) return;
    setState(() {
      _initialLoading = false;
      _loadingMore = false;
      if (result['statusCode'] == 200) {
        _rows.addAll((result['rows'] as List<dynamic>?) ?? const []);
        _hasMore = result['has_more'] == true;
      } else {
        _errorMessage = result['error'] as String? ?? 'Could not load credit history.';
      }
    });
  }

  String _formatDate(String isoDate) {
    final date = DateTime.parse(isoDate);
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec', //
    ];
    return '${months[date.month - 1]} ${date.day}, ${date.year}';
  }

  Color _statusColor(BuildContext context, String status) {
    return switch (status) {
      'available' => Colors.green,
      'partially_used' => Theme.of(context).colorScheme.primary,
      'expired' => Theme.of(context).colorScheme.error,
      _ => Theme.of(context).colorScheme.outline, // fully_used
    };
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Membership Credits History')),
      body: _buildBody(context),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (_initialLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_errorMessage != null && _rows.isEmpty) {
      return Center(child: Text(_errorMessage!, textAlign: TextAlign.center));
    }
    if (_rows.isEmpty) {
      return const Center(child: Text('No credit grants on file yet.'));
    }

    return ListView.builder(
      controller: _scrollController,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      itemCount: _rows.length + (_hasMore ? 1 : 0),
      itemBuilder: (context, index) {
        if (index >= _rows.length) {
          return const Padding(
            padding: EdgeInsets.symmetric(vertical: 16),
            child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
          );
        }

        final grant = _rows[index] as Map<String, dynamic>;
        final remaining = grant['remaining'] as int;
        final granted = grant['granted'] as int;
        final status = grant['status'] as String;

        return Card(
          margin: const EdgeInsets.symmetric(vertical: 4),
          child: ListTile(
            leading: const Icon(Icons.stars_outlined),
            title: Text('${grant['shift']} — ${_formatDate(grant['date'] as String)}'),
            subtitle: Text(
              status.replaceAll('_', ' '),
              style: TextStyle(color: _statusColor(context, status)),
            ),
            trailing: Text(
              '$remaining / $granted',
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
        );
      },
    );
  }
}
