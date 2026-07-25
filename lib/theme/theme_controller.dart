import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Owns the user's Light/Dark/System theme preference, persisted on-device
/// only (same as the Auto Check-In toggle) -- there's no backend field for
/// this, it's a per-device display preference, not a member-account setting.
class ThemeController extends ChangeNotifier {
  final FlutterSecureStorage _storage;

  static const _key = 'theme_mode';

  ThemeMode mode = ThemeMode.system;

  ThemeController({FlutterSecureStorage? storage}) : _storage = storage ?? const FlutterSecureStorage();

  Future<void> load() async {
    final stored = await _storage.read(key: _key);
    mode = switch (stored) {
      'light' => ThemeMode.light,
      'dark' => ThemeMode.dark,
      _ => ThemeMode.system,
    };
    notifyListeners();
  }

  Future<void> setMode(ThemeMode newMode) async {
    mode = newMode;
    notifyListeners();
    await _storage.write(key: _key, value: newMode.name);
  }
}
