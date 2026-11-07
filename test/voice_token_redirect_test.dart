import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

/// Pins the platform behaviour voice_token_transport.dart now relies on for
/// a Google Apps Script endpoint: ContentService answers a POST with a 302
/// to a one-time script.googleusercontent.com URL that serves the already
/// generated body. The transport's HTTPS-only endpoint validation cannot be
/// exercised against loopback, so this test drives the exact request shape
/// (followRedirects: true, JSON body, no Authorization header) through the
/// same http stack against two local servers and proves what crosses the
/// redirect hop.
void main() {
  test('dart:io does not auto-follow a 302 to a POST (transport handles it)',
      () async {
    String? originMethod;
    String? originBody;
    String? targetMethod;

    final target = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    target.listen((request) async {
      targetMethod = request.method;
      await request.drain<void>();
      request.response
        ..statusCode = 200
        ..headers.contentType = ContentType.json
        ..write(jsonEncode({
          'result': {'token': 'room-token', 'expiresInSeconds': 600},
        }));
      await request.response.close();
    });

    final origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    origin.listen((request) async {
      originMethod = request.method;
      originBody = await utf8.decoder.bind(request).join();
      request.response
        ..statusCode = 302
        ..headers.set('Location',
            'http://${InternetAddress.loopbackIPv4.address}:${target.port}/once-only')
        ..headers.contentType = ContentType.text;
      await request.response.close();
    });

    final client = IOClient(HttpClient());
    try {
      final idToken = 'id-token-under-test';
      final request = http.Request(
        'POST',
        Uri.parse(
          'http://${InternetAddress.loopbackIPv4.address}:${origin.port}/exec',
        ),
      )
        ..followRedirects = true
        ..headers.addAll({'Content-Type': 'application/json'})
        ..body = jsonEncode({
          'data': {'tableId': 'table', 'idToken': idToken},
        });
      final response = await client
          .send(request)
          .timeout(const Duration(seconds: 20));
      await response.stream.bytesToString();

      // Pinned platform behavior (dart:io http_impl.dart isRedirect): a
      // 302 after a POST is NOT auto-followed - only GET/HEAD redirects and
      // POST+303 are. This is why the transport follows the Apps Script hop
      // manually with a host allowlist.
      expect(response.statusCode, 302);
      expect(targetMethod, isNull, reason: 'redirect target never contacted');

      // Origin received the POST with the credential in its body only.
      expect(originMethod, 'POST');
      expect(originBody, contains(idToken));
    } finally {
      client.close();
      await origin.close(force: true);
      await target.close(force: true);
    }
  });
}
