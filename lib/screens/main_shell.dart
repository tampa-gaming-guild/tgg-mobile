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
/// tab but isn't dropped into it uninvited. Fetched once per login/relaunch,
/// not live-polled: if a session starts while the app is already open,
/// relaunch (or the old manual routes, now gone) is what used to pick that
/// up, and still is.
class MainShell extends StatefulWidget {
  final AuthRepository authRepository;
  final ThemeController themeController;

  const MainShell({super.key, required this.authRepository, required this.themeController});

  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> {
  final _api = ApiClient();
  bool _checking = true;
  bool _checkinWindowOpen = false;
  bool _canHost = false;
  int _selectedIndex = 0;

  @override
  void initState() {
    super.initState();
    _loadStatus();
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

  List<_ShellTab> _destinations(bool checkinWindowOpen, bool canHost) => [
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
            builder: (auth) => HostScreen(authRepository: auth),
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

    final tabs = _destinations(_checkinWindowOpen, _canHost);
    final selectedIndex = _selectedIndex.clamp(0, tabs.length - 1);

    return Scaffold(
      body: IndexedStack(
        index: selectedIndex,
        children: tabs.map((tab) => tab.builder(widget.authRepository)).toList(),
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
