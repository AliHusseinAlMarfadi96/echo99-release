import 'dart:convert';

import 'package:echo99/services/voice_token_client.dart';
import 'package:echo99/services/voice_token_transport.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test(
    'authenticated callable contract, no redirects, validates expiry',
    () async {
      final transport = VoiceTokenTransport(
        endpoint: 'https://example.invalid/token',
        idToken: () async => 'id-token',
        client: MockClient((r) async {
          expect(r.method, 'POST');
          expect(r.followRedirects, isFalse);
          expect(r.headers['Authorization'], 'Bearer id-token');
          expect(jsonDecode(r.body), {
            'data': {'tableId': 'table'},
          });
          return http.Response(
            jsonEncode({
              'result': {
                'token': 'room-token',
                'expiresInSeconds': 600,
                'canPublish': false,
              },
            }),
            200,
          );
        }),
      );
      expect(await transport.mint('table'), 'room-token');
      transport.close();
    },
  );
  for (final endpoint in [
    '',
    'http://example.invalid/token',
    'https://u:p@example.invalid',
    'https://example.invalid/?key=x',
    'https://example.invalid/#x',
  ]) {
    test('reject endpoint before auth or network: $endpoint', () async {
      var called = false;
      final t = VoiceTokenTransport(
        endpoint: endpoint,
        idToken: () async {
          called = true;
          return 'x';
        },
      );
      await expectLater(t.mint('table'), throwsA(isA<VoiceTokenException>()));
      expect(called, isFalse);
      t.close();
    });
  }
  test('signed out refuses without network', () async {
    final t = VoiceTokenTransport(
      endpoint: 'https://example.invalid/token',
      idToken: () async => null,
      client: MockClient((_) async => throw StateError('must not send')),
    );
    await expectLater(t.mint('table'), throwsA(isA<VoiceTokenException>()));
    t.close();
  });
  for (final status in [301, 401, 403, 429, 503]) {
    test('status $status fails without retaining response', () async {
      final t = VoiceTokenTransport(
        endpoint: 'https://example.invalid/token',
        idToken: () async => 'id',
        client: MockClient(
          (_) async => http.Response('secret-error-body', status),
        ),
      );
      try {
        await t.mint('table');
        fail('expected error');
      } catch (e) {
        expect(e, isA<VoiceTokenException>());
        expect(e.toString(), isNot(contains('secret-error-body')));
      }
      t.close();
    });
  }
  for (final body in [
    '{}',
    '{"error":{"message":"secret"}}',
    '{"result":{"token":"x","expiresInSeconds":0}}',
    '{"result":{"token":"x","expiresInSeconds":86401}}',
    'not json',
  ]) {
    test('malformed/expired response fails closed: $body', () async {
      final t = VoiceTokenTransport(
        endpoint: 'https://example.invalid/token',
        idToken: () async => 'id',
        client: MockClient((_) async => http.Response(body, 200)),
      );
      await expectLater(t.mint('table'), throwsA(isA<VoiceTokenException>()));
      t.close();
    });
  }
}
