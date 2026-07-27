import 'package:flutter/material.dart';

import 'auth/auth_repository.dart';
import 'config/app_config.dart';
import 'notifications/notification_service.dart';
import 'screens/login_screen.dart';
import 'screens/main_shell.dart';
import 'theme/theme_controller.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Before anything else: a bad TGG_ENV should stop the build being usable
  // rather than quietly serving up a localhost build that looks fine.
  AppConfig.validate();
  await NotificationService.init();
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
    final envLabel = AppConfig.label;

    return MaterialApp(
      title: 'TGG',
      theme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple)),
      darkTheme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple, brightness: Brightness.dark)),
      themeMode: widget.themeController.mode,
      // Replaces Flutter's own debug ribbon with one naming the backend,
      // which is the more useful fact: a release build pointed at test looks
      // identical to a real one otherwise, and this app writes check-ins.
      // Driven by TGG_ENV rather than debug/release for that reason. Doubles
      // as a typo check, since a misspelt TGG_ENV can't reach here at all
      // (AppConfig.validate) and a wrong-but-valid one shows the wrong label.
      debugShowCheckedModeBanner: false,
      builder: envLabel == null
          ? null
          : (context, child) => Banner(
                message: envLabel,
                location: BannerLocation.topEnd,
                color: AppConfig.isTest ? Colors.orange.shade700 : Colors.blueGrey.shade600,
                child: child ?? const SizedBox.shrink(),
              ),
      home: switch (widget.authRepository.status) {
        AuthStatus.unknown => const Scaffold(body: Center(child: CircularProgressIndicator())),
        AuthStatus.unauthenticated => LoginScreen(authRepository: widget.authRepository),
        AuthStatus.authenticated => MainShell(authRepository: widget.authRepository, themeController: widget.themeController),
      },
    );
  }
}
