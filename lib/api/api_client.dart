import 'dart:convert';

import 'package:http/http.dart' as http;

/// Thrown for auth calls that fail outright (bad credentials, locked
/// account, network error) -- as opposed to checkIn(), which returns
/// structured business-logic outcomes (already checked in, no session open,
/// etc.) as a normal map rather than throwing, since those aren't errors.
class ApiException implements Exception {
  final String message;
  final int? statusCode;
  ApiException(this.message, [this.statusCode]);

  @override
  String toString() => message;
}

/// Thrown by refresh() specifically for a transport-level failure (no
/// response at all -- offline, DNS, timeout). Callers must NOT treat this the
/// same as a clean rejection: a network hiccup says nothing about whether the
/// refresh token itself is still good, so the stored token must survive it --
/// otherwise one dropped connection would silently sign the user out.
class ApiConnectionException implements Exception {
  final Object cause;
  ApiConnectionException(this.cause);

  @override
  String toString() => 'ApiConnectionException: $cause';
}

/// Talks to the token API in the clubmanager repo
/// (public_html/member/api/). Dev-only base URL for now -- reached from a
/// physical device via `adb reverse tcp:8080 tcp:8080` rather than a LAN IP.
class ApiClient {
  static const String baseUrl = 'http://localhost:8080/member/api';

  Future<Map<String, dynamic>> login(String email, String password, {String? deviceLabel}) async {
    final response = await http.post(
      Uri.parse('$baseUrl/auth/token.php'),
      headers: const {'Content-Type': 'application/json'},
      body: jsonEncode({
        'email': email,
        'password': password,
        'device_label': ?deviceLabel,
      }),
    );
    final body = _decode(response);
    if (response.statusCode != 200) {
      throw ApiException(body['error'] as String? ?? 'Login failed', response.statusCode);
    }
    return body;
  }

  /// Returns null on a clean rejection (expired/revoked refresh token --
  /// really is "sign in again"). Throws [ApiConnectionException] if the
  /// request never got a response at all, so callers can tell "the token is
  /// bad" apart from "we're offline" and only clear stored state for the former.
  Future<Map<String, dynamic>?> refresh(String refreshToken) async {
    http.Response response;
    try {
      response = await http.post(
        Uri.parse('$baseUrl/auth/refresh.php'),
        headers: const {'Content-Type': 'application/json'},
        body: jsonEncode({'refresh_token': refreshToken}),
      );
    } catch (e) {
      throw ApiConnectionException(e);
    }

    if (response.statusCode != 200) return null;
    return _decode(response);
  }

  /// Best-effort: the local session is cleared by the caller regardless of
  /// whether this network call succeeds.
  Future<void> logout(String refreshToken) async {
    try {
      await http.post(
        Uri.parse('$baseUrl/auth/logout.php'),
        headers: const {'Content-Type': 'application/json'},
        body: jsonEncode({'refresh_token': refreshToken}),
      );
    } catch (_) {
      // ignore
    }
  }

  /// Returns the decoded response body regardless of status code -- the
  /// endpoint's success/error/redirect_reason fields are the real result,
  /// not an HTTP-level exception. statusCode is included for the one case
  /// the caller needs it: retrying once on a 401 (expired access token).
  Future<Map<String, dynamic>> checkIn(String accessToken) async {
    final response = await http.post(
      Uri.parse('$baseUrl/checkins.php'),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $accessToken',
      },
      body: jsonEncode(const {}),
    );
    return {..._decode(response), 'statusCode': response.statusCode};
  }

  /// Returns the decoded response body regardless of status code, same
  /// contract as checkIn() -- callers retry once on a 401 (expired access
  /// token) via statusCode rather than this throwing.
  Future<Map<String, dynamic>> getProfile(String accessToken) async {
    final response = await http.get(
      Uri.parse('$baseUrl/profile.php'),
      headers: {'Authorization': 'Bearer $accessToken'},
    );
    return {..._decode(response), 'statusCode': response.statusCode};
  }

  /// Dispatches a profile.php self-service action (update_settings,
  /// toggle_auto_renew, toggle_auto_apply_credits, request_email_change,
  /// cancel_email_change, trigger_password_reset). Same
  /// decode-regardless-of-status contract as checkIn()/getProfile().
  Future<Map<String, dynamic>> postProfileAction(String accessToken, String action, [Map<String, dynamic> fields = const {}]) async {
    final response = await http.post(
      Uri.parse('$baseUrl/profile.php'),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $accessToken',
      },
      body: jsonEncode({'action': action, ...fields}),
    );
    return {..._decode(response), 'statusCode': response.statusCode};
  }

  Map<String, dynamic> _decode(http.Response response) {
    if (response.body.isEmpty) return {};
    return jsonDecode(response.body) as Map<String, dynamic>;
  }
}
