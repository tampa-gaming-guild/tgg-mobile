import 'dart:convert';

import 'package:http/http.dart' as http;

import '../config/app_config.dart';

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
/// (public_html/member/api/).
class ApiClient {
  /// Chosen at build time, see AppConfig. Cleartext is permitted only for
  /// localhost, so any deployed target has to be HTTPS (see
  /// res/xml/network_security_config.xml).
  static const String baseUrl = AppConfig.baseUrl;

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
  Future<Map<String, dynamic>> checkIn(String accessToken, {List<String> guestNames = const []}) async {
    final response = await http.post(
      Uri.parse('$baseUrl/checkins.php'),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $accessToken',
      },
      body: jsonEncode({'guest_names': guestNames}),
    );
    return {..._decode(response), 'statusCode': response.statusCode};
  }

  /// The caller's own guest-pass allowance/remaining for the current
  /// calendar month, used to decide whether to show a "bring a guest?"
  /// toggle before checking in.
  Future<Map<String, dynamic>> guestPasses(String accessToken) async {
    final response = await http.get(
      Uri.parse('$baseUrl/guest-passes.php'),
      headers: {'Authorization': 'Bearer $accessToken'},
    );
    return {..._decode(response), 'statusCode': response.statusCode};
  }

  /// The renewable plan list (excludes Trial) for the caller's own
  /// self-service Renew screen.
  Future<Map<String, dynamic>> subscriptionPlans(String accessToken) async {
    final response = await http.get(
      Uri.parse('$baseUrl/subscription-plans.php'),
      headers: {'Authorization': 'Bearer $accessToken'},
    );
    return {..._decode(response), 'statusCode': response.statusCode};
  }

  /// Creates a Stripe Checkout session for the caller's own renewal and
  /// returns its URL, for the app to open in an in-app webview. Self-service
  /// only, always Card via Stripe -- Cash/Card-on-file are host-initiated
  /// only (see hostRenew()/hostCheckoutSession()).
  Future<Map<String, dynamic>> checkoutSession(String accessToken, {required int planId}) async {
    final response = await http.post(
      Uri.parse('$baseUrl/checkout-session.php'),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $accessToken',
      },
      body: jsonEncode({'plan_id': planId}),
    );
    return {..._decode(response), 'statusCode': response.statusCode};
  }

  /// Payment context (entrance fee owed, or the renewable tier list) for a
  /// check-in-blocking payment. [contactId] null = the caller's own
  /// (self-service check-in); non-null = a host checking that member in.
  Future<Map<String, dynamic>> paymentContext(String accessToken, {required String reason, int? contactId}) async {
    final path = contactId == null ? 'payment-context.php?reason=$reason' : 'host/payment-context.php?reason=$reason&contact_id=$contactId';
    final response = await http.get(
      Uri.parse('$baseUrl/$path'),
      headers: {'Authorization': 'Bearer $accessToken'},
    );
    return {..._decode(response), 'statusCode': response.statusCode};
  }

  /// Creates a Stripe Checkout session for a check-in-blocking payment.
  /// Returns either {checkout_url} or {pivoted_to_entrance_fee: true, ...}
  /// if a session-billed plan was selected for renewal (see
  /// PaymentFlow::resolveRenewalCharge on the backend). [contactId] null =
  /// self-service check-in; non-null = host checking that member in.
  Future<Map<String, dynamic>> paymentCheckoutSession(
    String accessToken, {
    required String reason,
    int? tierId,
    int? contactId,
  }) async {
    final path = contactId == null ? 'payment-checkout-session.php' : 'host/payment-checkout-session.php';
    final response = await http.post(
      Uri.parse('$baseUrl/$path'),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $accessToken',
      },
      body: jsonEncode({
        'reason': reason,
        'tier_id': ?tierId,
        'contact_id': ?contactId,
      }),
    );
    return {..._decode(response), 'statusCode': response.statusCode};
  }

  /// Requests a cash payment for a check-in-blocking payment -- pends host
  /// approval, never completes the check-in immediately. Same
  /// pivoted_to_entrance_fee contract as paymentCheckoutSession(). [contactId]
  /// null = self-service check-in; non-null = host checking that member in.
  Future<Map<String, dynamic>> paymentCash(
    String accessToken, {
    required String reason,
    int? tierId,
    int? contactId,
  }) async {
    final path = contactId == null ? 'payment-cash.php' : 'host/payment-cash.php';
    final response = await http.post(
      Uri.parse('$baseUrl/$path'),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $accessToken',
      },
      body: jsonEncode({
        'reason': reason,
        'tier_id': ?tierId,
        'contact_id': ?contactId,
      }),
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

  /// One page of the caller's full attendance history, for the "View All"
  /// screen behind profile.php's 3-row teaser.
  Future<Map<String, dynamic>> attendanceHistory(String accessToken, {required int offset, int limit = 20}) async {
    final response = await http.get(
      Uri.parse('$baseUrl/attendance-history.php?offset=$offset&limit=$limit'),
      headers: {'Authorization': 'Bearer $accessToken'},
    );
    return {..._decode(response), 'statusCode': response.statusCode};
  }

  /// One page of the caller's full billing history, same shape/contract as
  /// attendanceHistory().
  Future<Map<String, dynamic>> paymentHistory(String accessToken, {required int offset, int limit = 20}) async {
    final response = await http.get(
      Uri.parse('$baseUrl/payment-history.php?offset=$offset&limit=$limit'),
      headers: {'Authorization': 'Bearer $accessToken'},
    );
    return {..._decode(response), 'statusCode': response.statusCode};
  }

  /// One page of the caller's full Membership Credit grant history, for the
  /// "View All" screen behind profile.php's 3-row teaser.
  Future<Map<String, dynamic>> creditsHistory(String accessToken, {required int offset, int limit = 20}) async {
    final response = await http.get(
      Uri.parse('$baseUrl/credits-history.php?offset=$offset&limit=$limit'),
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

  /// Live member search for host check-in. Returns the decoded list
  /// regardless of status (an auth/permission failure surfaces as a JSON
  /// error map, same shape as everything else here).
  Future<List<dynamic>> hostSearch(String accessToken, String query) async {
    final response = await http.get(
      Uri.parse('$baseUrl/host/search.php?q=${Uri.encodeQueryComponent(query)}'),
      headers: {'Authorization': 'Bearer $accessToken'},
    );
    if (response.statusCode != 200) return [];
    final decoded = jsonDecode(response.body);
    return decoded is List ? decoded : [];
  }

  /// Same decode-regardless-of-status contract as checkIn().
  Future<Map<String, dynamic>> hostCheckIn(String accessToken, int contactId, {List<String> guestNames = const []}) async {
    final response = await http.post(
      Uri.parse('$baseUrl/host/checkin.php'),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $accessToken',
      },
      body: jsonEncode({'contact_id': contactId, 'guest_names': guestNames}),
    );
    return {..._decode(response), 'statusCode': response.statusCode};
  }

  /// A specific member's guest-pass allowance/remaining, shown in the host's
  /// check-in confirmation panel before deciding whether to add guest names.
  Future<Map<String, dynamic>> hostGuestPasses(String accessToken, int contactId) async {
    final response = await http.get(
      Uri.parse('$baseUrl/host/guest-passes.php?contact_id=$contactId'),
      headers: {'Authorization': 'Bearer $accessToken'},
    );
    return {..._decode(response), 'statusCode': response.statusCode};
  }

  /// A specific member's profile for the host to view/reference during
  /// renewals -- contact info, membership, credits, attendance, payment
  /// history. Read-only, no pagination (unlike the member's own profile).
  Future<Map<String, dynamic>> hostMemberProfile(String accessToken, int contactId) async {
    final response = await http.get(
      Uri.parse('$baseUrl/host/member-profile.php?contact_id=$contactId'),
      headers: {'Authorization': 'Bearer $accessToken'},
    );
    return {..._decode(response), 'statusCode': response.statusCode};
  }

  /// The renewable plan list (excludes Trial) for the Renew form.
  Future<Map<String, dynamic>> hostSubscriptionPlans(String accessToken) async {
    final response = await http.get(
      Uri.parse('$baseUrl/host/subscription-plans.php'),
      headers: {'Authorization': 'Bearer $accessToken'},
    );
    return {..._decode(response), 'statusCode': response.statusCode};
  }

  /// Records an immediate renewal -- 'card_on_file' (charges the member's
  /// stored Stripe payment method) or 'cash' (host-confirmed on the spot) --
  /// mirroring renew.php's simplified "Renew Membership" section. Always the
  /// standard plan period, always honoring the selected level.
  Future<Map<String, dynamic>> hostRenew(
    String accessToken, {
    required int contactId,
    required int planId,
    required String paymentMethod,
  }) async {
    final response = await http.post(
      Uri.parse('$baseUrl/host/renew.php'),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $accessToken',
      },
      body: jsonEncode({
        'contact_id': contactId,
        'plan_id': planId,
        'payment_method': paymentMethod,
      }),
    );
    return {..._decode(response), 'statusCode': response.statusCode};
  }

  /// Creates a Stripe Checkout session for a member's renewal (for when they
  /// have no card on file) and returns its URL, for the app to open in an
  /// in-app webview.
  Future<Map<String, dynamic>> hostCheckoutSession(String accessToken, {required int contactId, required int planId}) async {
    final response = await http.post(
      Uri.parse('$baseUrl/host/checkout-session.php'),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $accessToken',
      },
      body: jsonEncode({'contact_id': contactId, 'plan_id': planId}),
    );
    return {..._decode(response), 'statusCode': response.statusCode};
  }

  /// The Hosting Dashboard payload -- active session, today's check-in
  /// count, pending cash approvals, and the check-ins log -- or just
  /// {is_hosting_now: false} when the caller isn't signed up to host
  /// today's specific event (see host/dashboard.php).
  Future<Map<String, dynamic>> hostDashboard(String accessToken) async {
    final response = await http.get(
      Uri.parse('$baseUrl/host/dashboard.php'),
      headers: {'Authorization': 'Bearer $accessToken'},
    );
    return {..._decode(response), 'statusCode': response.statusCode};
  }

  Future<Map<String, dynamic>> resolvePendingPayment(String accessToken, int pendingId, String action) async {
    final response = await http.post(
      Uri.parse('$baseUrl/host/resolve-payment.php'),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $accessToken',
      },
      body: jsonEncode({'pending_id': pendingId, 'action': action}),
    );
    return {..._decode(response), 'statusCode': response.statusCode};
  }

  Future<Map<String, dynamic>> deleteCheckin(String accessToken, int checkinId) async {
    final response = await http.post(
      Uri.parse('$baseUrl/host/delete-checkin.php'),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $accessToken',
      },
      body: jsonEncode({'checkin_id': checkinId}),
    );
    return {..._decode(response), 'statusCode': response.statusCode};
  }

  /// Lightweight status check the bottom-nav shell calls once per
  /// login/relaunch to decide which tabs to show (Check-In, Hosting) and
  /// which opens by default. Unlike hostDashboard(), this works for any
  /// authenticated member, not just an 'edit checkins' holder.
  Future<Map<String, dynamic>> sessionStatus(String accessToken) async {
    final response = await http.get(
      Uri.parse('$baseUrl/session-status.php'),
      headers: {'Authorization': 'Bearer $accessToken'},
    );
    return {..._decode(response), 'statusCode': response.statusCode};
  }

  /// Upcoming events and their volunteer slots (open + filled, with who --
  /// same data volunteers.php's list view shows).
  Future<Map<String, dynamic>> volunteerSchedule(String accessToken) async {
    final response = await http.get(
      Uri.parse('$baseUrl/volunteer/schedule.php'),
      headers: {'Authorization': 'Bearer $accessToken'},
    );
    return {..._decode(response), 'statusCode': response.statusCode};
  }

  Future<Map<String, dynamic>> volunteerSignup(String accessToken, int slotId) async {
    final response = await http.post(
      Uri.parse('$baseUrl/volunteer/signup.php'),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $accessToken',
      },
      body: jsonEncode({'slot_id': slotId}),
    );
    return {..._decode(response), 'statusCode': response.statusCode};
  }

  Future<Map<String, dynamic>> volunteerCancel(String accessToken, int slotId) async {
    final response = await http.post(
      Uri.parse('$baseUrl/volunteer/cancel.php'),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $accessToken',
      },
      body: jsonEncode({'slot_id': slotId}),
    );
    return {..._decode(response), 'statusCode': response.statusCode};
  }

  Map<String, dynamic> _decode(http.Response response) {
    if (response.body.isEmpty) return {};
    return jsonDecode(response.body) as Map<String, dynamic>;
  }
}
