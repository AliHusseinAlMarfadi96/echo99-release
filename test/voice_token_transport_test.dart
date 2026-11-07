import 'dart:convert';

import 'package:echo99/services/voice_token_client.dart';
import 'package:echo99/services/voice_token_transport.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test(
    'authenticated contract: token in body, no header, no auto redirect',
    () async {
      final transport = VoiceTokenTransport(
        endpoint: 'https://example.invalid/token',
        idToken: () async => 'id-token',
        client: MockClient((r) async {
          expect(r.method, 'POST');
          // Redirects are followed manually with a host allowlist.
          expect(r.followRedirects, isFalse);
          // The ID token travels in the body so the redirect hop is never
          // forwarded an Authorization credential.
          expect(r.headers['Authorization'], isNull);
          expect(jsonDecode(r.body), {
            'data': {'tableId': 'table', 'idToken': 'id-token'},
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

  group('issuer redirect handling', () {
    test('follows one allowlisted googleusercontent hop as bodiless GET',
        () async {
      final seen = <http.BaseRequest>[];
      final transport = VoiceTokenTransport(
        endpoint: 'https://script.google.com/macros/s/abc/exec',
        idToken: () async => 'id-token',
        client: MockClient((r) async {
          seen.add(r);
          if (seen.length == 1) {
            return http.Response('', 302, headers: {
              'location':
                  'https://abc123-script.googleusercontent.com/once',
            });
          }
          return http.Response(
            jsonEncode({
              'result': {'token': 'room-token', 'expiresInSeconds': 600},
            }),
            200,
          );
        }),
      );
      expect(await transport.mint('table'), 'room-token');
      expect(seen.length, 2);
      expect(seen[0].method, 'POST');
      expect(seen[1].method, 'GET');
      expect(seen[1].url.host, 'abc123-script.googleusercontent.com');
      expect((seen[1] as http.Request).body, isEmpty);
      expect(seen[1].headers['Authorization'], isNull);
      transport.close();
    });

    for (final location in [
      'https://evil.example/steal',
      'http://script.googleusercontent.com/insecure',
      'https://u:p@script.googleusercontent.com/userinfo',
      'not a uri',
    ]) {
      test('rejects redirect to untrusted target: \$location', () async {
        var calls = 0;
        final transport = VoiceTokenTransport(
          endpoint: 'https://script.google.com/macros/s/abc/exec',
          idToken: () async => 'id-token',
          client: MockClient((r) async {
            calls++;
            return http.Response('', 302, headers: {'location': location});
          }),
        );
        await expectLater(
          transport.mint('table'),
          throwsA(isA<VoiceTokenException>()),
        );
        expect(calls, 1, reason: 'untrusted redirect must not be followed');
        transport.close();
      });
    }

    test('redirect without location fails closed', () async {
      final transport = VoiceTokenTransport(
        endpoint: 'https://script.google.com/macros/s/abc/exec',
        idToken: () async => 'id-token',
        client: MockClient((r) async => http.Response('', 302)),
      );
      await expectLater(
        transport.mint('table'),
        throwsA(isA<VoiceTokenException>()),
      );
      transport.close();
    });
  });
}
