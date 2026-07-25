import 'package:flutter/material.dart';

import '../api/api_client.dart';
import '../auth/auth_repository.dart';

/// Full, pageable attendance history behind the Home page's 3-row teaser.
/// Loads more as the user scrolls near the bottom (infinite scroll) rather
/// than a page-number/"Load More" control.
class AttendanceHistoryScreen extends StatefulWidget {
  final AuthRepository authRepository;

  const AttendanceHistoryScreen({super.key, required this.authRepository});

  @override
  State<AttendanceHistoryScreen> createState() => _AttendanceHistoryScreenState();
}

class _AttendanceHistoryScreenState extends State<AttendanceHistoryScreen> {
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
      (token) => _api.attendanceHistory(token, offset: _rows.length, limit: _pageSize),
    );

    if (!mounted) return;
    setState(() {
      _initialLoading = false;
      _loadingMore = false;
      if (result['statusCode'] == 200) {
        _rows.addAll((result['rows'] as List<dynamic>?) ?? const []);
        _hasMore = result['has_more'] == true;
      } else {
        _errorMessage = result['error'] as String? ?? 'Could not load attendance history.';
      }
    });
  }

  // Date only -- the time of day isn't meaningful information here.
  String _formatDate(String isoDateTime) {
    final date = DateTime.parse(isoDateTime);
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec', //
    ];
    return '${months[date.month - 1]} ${date.day}, ${date.year}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Attendance History')),
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
      return const Center(child: Text('No check-ins on file yet.'));
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

        final row = _rows[index] as Map<String, dynamic>;
        final guestName = row['guest_name'] as String?;
        final label = guestName != null ? 'Guest: $guestName' : (row['notes'] as String? ?? 'Visit');

        return Card(
          margin: const EdgeInsets.symmetric(vertical: 4),
          child: ListTile(
            leading: const Icon(Icons.event_available_outlined),
            title: Text(_formatDate(row['checked_in_at'] as String)),
            subtitle: Text(label),
          ),
        );
      },
    );
  }
}
