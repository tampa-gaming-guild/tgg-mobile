import 'package:flutter/material.dart';

import 'auth/auth_repository.dart';
import 'screens/login_screen.dart';
import 'screens/main_shell.dart';
import 'theme/theme_controller.dart';

void main() {
  runApp(TggApp(authRepository: AuthRepository(), themeController: ThemeController()));
}

class TggApp extends StatefulWidget {
  final AuthRepository authRepository;
  final ThemeController themeController;

  const TggApp({super.key, required this.authRepository, required this.themeController});

  @override
  State<TggApp> createState() => _TggAppState();
}

class _TggAppState extends State<TggApp> {
  @override
  void initState() {
    super.initState();
    widget.authRepository.addListener(_onChanged);
    widget.authRepository.tryAutoLogin();
    widget.themeController.addListener(_onChanged);
    widget.themeController.load();
  }

  @override
  void dispose() {
    widget.authRepository.removeListener(_onChanged);
    widget.themeController.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() => setState(() {});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'TGG',
      theme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple)),
      darkTheme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple, brightness: Brightness.dark)),
      themeMode: widget.themeController.mode,
      home: switch (widget.authRepository.status) {
        AuthStatus.unknown => const Scaffold(body: Center(child: CircularProgressIndicator())),
        AuthStatus.unauthenticated => LoginScreen(authRepository: widget.authRepository),
        AuthStatus.authenticated => MainShell(authRepository: widget.authRepository, themeController: widget.themeController),
      },
    );
  }
}
