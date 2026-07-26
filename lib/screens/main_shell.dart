import 'dart:async';

import 'package:flutter/material.dart';

import '../api/api_client.dart';
import '../auth/auth_repository.dart';
import '../theme/theme_controller.dart';
import 'checkin_screen.dart';
import 'host_screen.dart';
import 'profile_screen.dart';
import 'volunteer_screen.dart';

/// Post-login bottom-nav shell: Home, Hosting, Check-In, Volunteer. Home
/// shows the member's profile (membership, credits, attendance) and its own
/// gear icon leads to the editable account-settings screen -- no separate
/// Settings tab, since that's a less-frequently-used destination. Check-In
/// only appears while a check-in window is open. Hosting only appears for an
/// 'edit checkins' holder while a session is active -- same looser-than-web
/// rule host_screen.dart already documents -- and lands right after Home
/// (2nd position) whenever it's present, but is only *auto-selected* by
/// default when the caller is actually signed up as today's host/volunteer
/// (is_hosting_now); an admin who merely holds the permission still sees the
/// tab but isn't dropped into it uninvited.
///
/// Tab visibility is re-checked every 5 minutes (a session's hosting window
/// opens 2 hours before its start_time -- see Event::getActiveSession() --
/// so 5-minute granularity is plenty to catch that transition), so the
/// Hosting/Check-In tabs can appear without a relaunch if a window opens
/// while the app is already running -- that's also what lets HostScreen's
/// own faster 20-second pending-payment poll start. Also re-checked whenever
/// the app resumes from the background: Android often suspends the whole
/// Dart isolate while backgrounded, so the 5-minute timer can't be trusted
/// to "catch up" on its own the moment the app is reopened. Both refreshes
/// deliberately never touch the selected tab -- they shouldn't yank the user
/// off whatever tab they're actually using.
class MainShell extends StatefulWidget {
  final AuthRepository authRepository;
  final ThemeController themeController;

  const MainShell({super.key, required this.authRepository, required this.themeController});

  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> with WidgetsBindingObserver {
  static const _statusPollInterval = Duration(minutes: 5);

  final _api = ApiClient();
  bool _checking = true;
  bool _checkinWindowOpen = false;
  bool _canHost = false;
  int _selectedIndex = 0;
  Timer? _statusPollTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadStatus();
    _statusPollTimer = Timer.periodic(_statusPollInterval, (_) => _refreshStatus());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _statusPollTimer?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refreshStatus();
  }

  Future<void> _loadStatus() async {
    final result = await widget.authRepository.authedCall(_api.sessionStatus);
    if (!mounted) return;

    final canHost = result['can_host'] == true;
    final isHostingNow = result['is_hosting_now'] == true;
    setState(() {
      _checking = false;
      _checkinWindowOpen = result['is_checkin_window_open'] == true;
      _canHost = canHost;
      // Hosting always lands right after Home (index 1) whenever it's
      // present -- select it by index so this stays in sync without
      // duplicating that position number here.
      _selectedIndex = isHostingNow ? 1 : 0;
    });
  }

  /// The periodic re-check -- see the class doc comment. Only ever updates
  /// which tabs are shown, never _selectedIndex.
  Future<void> _refreshStatus() async {
    final result = await widget.authRepository.authedCall(_api.sessionStatus);
    if (!mounted) return;
    setState(() {
      _checkinWindowOpen = result['is_checkin_window_open'] == true;
      _canHost = result['can_host'] == true;
    });
  }

  List<_ShellTab> _destinations(bool checkinWindowOpen, bool canHost, int selectedIndex) => [
        _ShellTab(
          icon: Icons.home_outlined,
          selectedIcon: Icons.home,
          label: 'Home',
          builder: (auth) => ProfileScreen(authRepository: auth, themeController: widget.themeController),
        ),
        if (canHost)
          _ShellTab(
            icon: Icons.badge_outlined,
            selectedIcon: Icons.badge,
            label: 'Hosting',
            // Hosting always lands at index 1 when present -- see _loadStatus.
            builder: (auth) => HostScreen(authRepository: auth, isActive: selectedIndex == 1),
          ),
        if (checkinWindowOpen)
          _ShellTab(
            icon: Icons.check_circle_outline,
            selectedIcon: Icons.check_circle,
            label: 'Check-In',
            builder: (auth) => CheckInScreen(authRepository: auth),
          ),
        _ShellTab(
          icon: Icons.volunteer_activism_outlined,
          selectedIcon: Icons.volunteer_activism,
          label: 'Volunteer',
          builder: (auth) => VolunteerScreen(authRepository: auth),
        ),
      ];

  @override
  Widget build(BuildContext context) {
    if (_checking) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    final tabs = _destinations(_checkinWindowOpen, _canHost, _selectedIndex);
    final selectedIndex = _selectedIndex.clamp(0, tabs.length - 1);

    return Scaffold(
      body: IndexedStack(
        index: selectedIndex,
        // Keyed by label -- now that tabs can appear/disappear mid-session
        // (see _refreshStatus), a plain position-based diff would treat an
        // inserted/removed tab as replacing every tab after it, wiping their
        // state (scroll position, loaded data) for no reason.
        children: tabs.map((tab) => KeyedSubtree(key: ValueKey(tab.label), child: tab.builder(widget.authRepository))).toList(),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: selectedIndex,
        onDestinationSelected: (index) => setState(() => _selectedIndex = index),
        destinations: tabs
            .map((tab) => NavigationDestination(
                  icon: Icon(tab.icon),
                  selectedIcon: Icon(tab.selectedIcon),
                  label: tab.label,
                ))
            .toList(),
      ),
    );
  }
}

class _ShellTab {
  final IconData icon;
  final IconData selectedIcon;
  final String label;
  final Widget Function(AuthRepository) builder;

  _ShellTab({required this.icon, required this.selectedIcon, required this.label, required this.builder});
}
