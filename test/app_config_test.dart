import 'package:flutter_test/flutter_test.dart';

import 'package:tgg_mobile/api/api_client.dart';
import 'package:tgg_mobile/config/app_config.dart';

/// Asserts the TGG_ENV mapping actually resolves, rather than that the URL
/// strings merely appear in the build. Grepping the compiled output can't
/// distinguish a live base URL from the same URL quoted inside a validate()
/// error message, and picking the wrong backend is not a mistake this app can
/// afford quietly: the same build writes real check-ins, on its own, to
/// whichever server it was compiled against.
///
/// Run under each environment, since TGG_ENV is compile time:
///
///     flutter test                              # dev, the default
///     flutter test --dart-define=TGG_ENV=test   # test
void main() {
  test('resolves a backend consistent with the reported environment', () {
    if (AppConfig.isTest) {
      expect(AppConfig.baseUrl, 'https://tampagamingguild.org/member/api');
      expect(AppConfig.label, 'TEST');
    } else {
      expect(AppConfig.isDev, isTrue);
      expect(AppConfig.baseUrl, 'http://localhost:8080/member/api');
      expect(AppConfig.label, 'DEV');
    }
  });

  test('ApiClient talks to the configured backend', () {
    expect(ApiClient.baseUrl, AppConfig.baseUrl);
  });

  test('validate accepts the environment this build was compiled with', () {
    expect(AppConfig.validate, returnsNormally);
  });

  test('a deployed backend is HTTPS, since cleartext is localhost only', () {
    expect(
      AppConfig.baseUrl.startsWith('https://') || Uri.parse(AppConfig.baseUrl).host == 'localhost',
      isTrue,
      reason: 'network_security_config.xml permits cleartext for localhost only',
    );
  });

  test('no production target is wired up while /api still serves WordPress', () {
    expect(AppConfig.isProduction, isFalse);
    expect(AppConfig.label, isNotNull, reason: 'every current build should announce its environment');
  });
}
