import 'package:flutter/material.dart';

import 'auth/auth_repository.dart';
import 'screens/home_screen.dart';
import 'screens/login_screen.dart';

void main() {
  runApp(TggApp(authRepository: AuthRepository()));
}

class TggApp extends StatefulWidget {
  final AuthRepository authRepository;

  const TggApp({super.key, required this.authRepository});

  @override
  State<TggApp> createState() => _TggAppState();
}

class _TggAppState extends State<TggApp> {
  @override
  void initState() {
    super.initState();
    widget.authRepository.addListener(_onAuthChanged);
    widget.authRepository.tryAutoLogin();
  }

  @override
  void dispose() {
    widget.authRepository.removeListener(_onAuthChanged);
    super.dispose();
  }

  void _onAuthChanged() => setState(() {});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'TGG',
      theme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple)),
      darkTheme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple, brightness: Brightness.dark)),
      // Explicit for clarity -- this is already MaterialApp's default, but a
      // dark theme without themeMode: system reads as easy to forget.
      themeMode: ThemeMode.system,
      home: switch (widget.authRepository.status) {
        AuthStatus.unknown => const Scaffold(body: Center(child: CircularProgressIndicator())),
        AuthStatus.unauthenticated => LoginScreen(authRepository: widget.authRepository),
        AuthStatus.authenticated => HomeScreen(authRepository: widget.authRepository),
      },
    );
  }
}
