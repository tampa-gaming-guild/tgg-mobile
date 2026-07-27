/// Which backend this build talks to, fixed at compile time with
/// `--dart-define=TGG_ENV=<dev|test>` and defaulting to `dev`.
///
/// Named environments rather than a raw URL define on purpose: the path
/// differs per environment as well as the host, so handing the whole URL to
/// whoever types the build command turns a typo into a plausible looking but
/// wrong target. Here that mapping lives in one place, and [label] is shown
/// on screen so a build always says which backend it is talking to.
class AppConfig {
  static const String _env = String.fromEnvironment('TGG_ENV', defaultValue: 'dev');

  static const bool isDev = _env == 'dev';
  static const bool isTest = _env == 'test';

  /// There is no production target yet. `https://tampagamingguild.org/api`
  /// is still served by the WordPress/CiviCRM site, so a build pointed there
  /// would fire login and check-in requests at the live public site and get
  /// HTML back rather than JSON. [validate] refuses `prod` for that reason;
  /// wire it up when the real docroot moves to `public_html/member/`.
  static const bool isProduction = false;

  static const String baseUrl = isTest
      ? 'https://tampagamingguild.org/member/api'
      : 'http://localhost:8080/member/api';

  /// Shown as a corner ribbon and in Account Settings. Null once a genuine
  /// production build exists, since that is the one case worth no chrome.
  static String? get label => isProduction ? null : (isTest ? 'TEST' : 'DEV');

  /// Called before the app builds anything. Deliberately fatal: an
  /// unrecognised value would otherwise fall through to the dev URL and give
  /// you a localhost build while you believed you were testing a server.
  static void validate() {
    if (isDev || isTest) return;

    if (_env == 'prod') {
      throw StateError(
        'TGG_ENV=prod is not available yet: https://tampagamingguild.org/ still serves the '
        'WordPress/CiviCRM site, so this build would talk to that instead of the member API. '
        'Build with TGG_ENV=test against https://tampagamingguild.org/member/api, or omit it for local dev.',
      );
    }

    throw StateError(
      'Unrecognised TGG_ENV "$_env". Valid values are "dev" (default, local backend '
      'via adb reverse) and "test" (https://tampagamingguild.org/member/api).',
    );
  }
}
