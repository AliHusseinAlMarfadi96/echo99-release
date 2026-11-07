import 'dart:convert';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:http/http.dart' as http;

import 'voice_token_client.dart';

/// Authenticated token transport. The URL is public configuration, never a key.
/// Compatible with Firebase callable JSON and an equivalent free HTTPS server.
///
/// The current issuer is a Google Apps Script web app: it cannot read
/// request headers, so the Firebase ID token travels in the POST body, and
/// its ContentService response is served through a 302 to a one-time
/// script.googleusercontent.com URL. dart:io only auto-follows redirects
/// for GET/HEAD (for POST only on 303), so the single hop is followed
/// manually and restricted to the Google hosts that serve Apps Script
/// output. The follow-up request is a bodiless GET with no Authorization
/// header: the ID token never crosses the redirect hop.
class VoiceTokenTransport {
  VoiceTokenTransport({
    required String endpoint,
    required this.idToken,
    http.Client? client,
  }) : _endpoint = _safeEndpoint(endpoint),
       _client = client ?? http.Client();

  static const configuredEndpoint = String.fromEnvironment(
    'VOICE_TOKEN_ENDPOINT',
  );
  final Uri? _endpoint;
  final Future<String?> Function() idToken;
  final http.Client _client;

  static Uri? _safeEndpoint(String value) {
    final uri = Uri.tryParse(value);
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasFragment ||
        uri.hasQuery) {
      return null;
    }
    return uri;
  }

  factory VoiceTokenTransport.configured() => VoiceTokenTransport(
    endpoint: configuredEndpoint,
    idToken: () async => FirebaseAuth.instance.currentUser?.getIdToken(),
  );

  Future<Map<String, dynamic>> call(String tableId) async {
    if (tableId.isEmpty || tableId.contains('/') || tableId.length > 256) {
      throw const VoiceTokenException('invalid table id');
    }
    return _post({'tableId': tableId});
  }

  /// Host-only moderation: the issuer verifies the caller owns the room's
  /// voice authority document, then applies [op] ('mute' | 'unmute' |
  /// 'kick') to [targetId] inside the live LiveKit room. Best-effort: the
  /// durable state change is the voiceRooms write the caller already made.
  Future<void> moderate({
    required String tableId,
    required String targetId,
    required String op,
  }) async {
    if (tableId.isEmpty || tableId.contains('/') || tableId.length > 256) {
      throw const VoiceTokenException('invalid table id');
    }
    if (targetId.isEmpty || targetId.contains('/') || targetId.length > 256) {
      throw const VoiceTokenException('invalid target id');
    }
    if (!const {'mute', 'unmute', 'kick'}.contains(op)) {
      throw const VoiceTokenException('invalid moderation op');
    }
    await _post({
      'action': 'moderate',
      'tableId': tableId,
      'targetId': targetId,
      'op': op,
    });
  }

  Future<Map<String, dynamic>> _post(Map<String, dynamic> data) async {
    final endpoint = _endpoint;
    if (endpoint == null) {
      throw const VoiceTokenException('voice endpoint is not configured');
    }
    final token = await idToken().timeout(const Duration(seconds: 12));
    if (token == null || token.isEmpty) {
      throw const VoiceTokenException('sign in before joining voice');
    }
    try {
      final request = http.Request('POST', endpoint)
        // Redirects are followed manually with a host allowlist, never
        // automatically (see _followIssuerRedirect).
        ..followRedirects = false
        ..headers.addAll({'Content-Type': 'application/json'})
        // Apps Script cannot read request headers, so the ID token goes in
        // the body.
        ..body = jsonEncode({
          'data': {...data, 'idToken': token},
        });
      var response = await _client
          .send(request)
          // Apps Script cold starts plus two upstream calls can exceed the
          // old 12s budget; 20s keeps voice joins reliable.
          .timeout(const Duration(seconds: 20));
      response = await _followIssuerRedirect(response);
      if (response.statusCode != 200) {
        // Do not retain response/error bodies: they could contain credentials.
        await response.stream.listen((_) {}).cancel();
        throw const VoiceTokenException('voice endpoint rejected request');
      }
      var size = 0;
      final bytes = <int>[];
      await for (final chunk in response.stream.timeout(
        const Duration(seconds: 12),
      )) {
        size += chunk.length;
        if (size > 65536) {
          throw const VoiceTokenException('invalid voice response');
        }
        bytes.addAll(chunk);
      }
      final payload = jsonDecode(utf8.decode(bytes));
      if (payload is! Map<String, dynamic> || payload['error'] != null) {
        throw const VoiceTokenException('invalid voice response');
      }
      final result = payload['result'] ?? payload['data'];
      if (result is! Map<String, dynamic>) {
        throw const VoiceTokenException('invalid voice response');
      }
      return result;
    } catch (_) {
      throw const VoiceTokenException('voice endpoint unavailable');
    }
  }

  /// Apps Script's ContentService answers a POST with a 302 to a one-time
  /// URL that serves the already-generated response body. That hop is
  /// followed here, once, only to the Google hosts that serve Apps Script
  /// output, as a bodiless GET carrying no headers: the ID token from the
  /// POST body never reaches the redirect target.
  Future<http.StreamedResponse> _followIssuerRedirect(
    http.StreamedResponse response,
  ) async {
    const redirectStatuses = {301, 302, 303, 307, 308};
    if (!redirectStatuses.contains(response.statusCode)) return response;
    final location = response.headers['location'];
    await response.stream.listen((_) {}).cancel();
    final target = location == null ? null : _safeRedirectTarget(location);
    if (target == null) {
      throw const VoiceTokenException('invalid voice response');
    }
    final follow = http.Request('GET', target)..followRedirects = false;
    return _client.send(follow).timeout(const Duration(seconds: 20));
  }

  static Uri? _safeRedirectTarget(String location) {
    final uri = Uri.tryParse(location);
    if (uri == null || uri.scheme != 'https' || uri.userInfo.isNotEmpty) {
      return null;
    }
    final host = uri.host;
    // Apps Script serves ContentService output from
    // script.googleusercontent.com/macros/echo?user_content_key=... and
    // from hosts of the form <id>-script.googleusercontent.com. Both are
    // Google-owned; no other host may receive the follow-up request.
    const allowed = {'script.google.com', 'script.googleusercontent.com'};
    if (!allowed.contains(host) &&
        !host.endsWith('.script.googleusercontent.com') &&
        !host.endsWith('-script.googleusercontent.com')) {
      return null;
    }
    return uri;
  }

  Future<String> mint(String tableId) async =>
      (await VoiceTokenClient(call: call).mint(tableId)).token;

  void close() => _client.close();
}
