import 'package:echo99/services/voice_token_client.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('VoiceTokenClient', () {
    test('parses token, mic grant, and refresh time', () async {
      var now = DateTime.fromMillisecondsSinceEpoch(1000000);
      final client = VoiceTokenClient(
        now: () => now,
        call: (tableId) async {
          expect(tableId, 't1');
          return {
            'token': 'jwt',
            'expiresInSeconds': 21600,
            'canPublish': true,
          };
        },
      );
      final t = await client.mint('t1');
      expect(t.token, 'jwt');
      expect(t.canPublish, isTrue);
      // 80% of 6h = 4h48m after "now".
      expect(
        t.refreshAfter.millisecondsSinceEpoch - now.millisecondsSinceEpoch,
        (21600 * 1000 * 0.8).round(),
      );
    });

    test('host-muted seat comes back listen-only', () async {
      final client = VoiceTokenClient(
        call: (_) async => {
          'token': 'jwt',
          'expiresInSeconds': 21600,
          'canPublish': false,
        },
      );
      final t = await client.mint('t1');
      expect(t.canPublish, isFalse);
    });

    test('missing token or expiry is an error, not a silent join', () async {
      final noToken = VoiceTokenClient(
        call: (_) async => {'expiresInSeconds': 21600},
      );
      expect(() => noToken.mint('t1'), throwsA(isA<VoiceTokenException>()));
      final noTtl = VoiceTokenClient(call: (_) async => {'token': 'jwt'});
      expect(() => noTtl.mint('t1'), throwsA(isA<VoiceTokenException>()));
    });

    test('call failures surface as VoiceTokenException', () async {
      final client = VoiceTokenClient(call: (_) async => throw 'boom');
      expect(() => client.mint('t1'), throwsA(isA<VoiceTokenException>()));
    });

    test('unbound client refuses instead of inventing a token', () async {
      final client = VoiceTokenClient();
      expect(() => client.mint('t1'), throwsA(isA<VoiceTokenException>()));
    });

    test('empty table id is rejected before any call', () async {
      var called = false;
      final client = VoiceTokenClient(
        call: (_) async {
          called = true;
          return {};
        },
      );
      expect(() => client.mint(''), throwsA(isA<VoiceTokenException>()));
      expect(called, isFalse);
    });
  });
}
