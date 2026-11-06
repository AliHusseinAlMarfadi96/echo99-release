import 'dart:convert';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:http/http.dart' as http;

import 'voice_token_client.dart';

/// Authenticated token transport. The URL is public configuration, never a key.
/// Compatible with Firebase callable JSON and an equivalent free HTTPS server.
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
    final endpoint = _endpoint;
    if (endpoint == null) {
      throw const VoiceTokenException('voice endpoint is not configured');
    }
    if (tableId.isEmpty || tableId.contains('/') || tableId.length > 256) {
      throw const VoiceTokenException('invalid table id');
    }
    final token = await idToken().timeout(const Duration(seconds: 12));
    if (token == null || token.isEmpty) {
      throw const VoiceTokenException('sign in before joining voice');
    }
    try {
      final request = http.Request('POST', endpoint)
        ..followRedirects = false
        ..headers.addAll({
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/json',
        })
        ..body = jsonEncode({
          'data': {'tableId': tableId},
        });
      final response = await _client
          .send(request)
          .timeout(const Duration(seconds: 12));
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

  Future<String> mint(String tableId) async =>
      (await VoiceTokenClient(call: call).mint(tableId)).token;

  void close() => _client.close();
}
