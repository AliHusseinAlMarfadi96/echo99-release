import 'package:echo99/services/voice_authority.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:echo99/services/voice_token_transport.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('VoiceMember', () {
    test('round-trips its exact rules-enforced shape', () {
      const m = VoiceMember(muted: true, banned: false, present: true);
      expect(m.toMap(), {'muted': true, 'banned': false, 'present': true});
      final parsed = VoiceMember.fromMap(m.toMap());
      expect(parsed!.muted, isTrue);
      expect(parsed.banned, isFalse);
      expect(parsed.present, isTrue);
    });

    test('fails closed on malformed entries', () {
      expect(VoiceMember.fromMap(null), isNull);
      expect(VoiceMember.fromMap('x'), isNull);
      expect(VoiceMember.fromMap({'muted': true}), isNull);
      expect(
        VoiceMember.fromMap({'muted': 1, 'banned': false, 'present': false}),
        isNull,
      );
      // Extra fields still parse (reader side is lenient; writer side is exact).
      final withExtra = VoiceMember.fromMap({
        'muted': false,
        'banned': false,
        'present': false,
        'admin': true,
      });
      expect(withExtra, isNotNull);
    });
  });

  group('canSelfJoinListener (owner policy: self-join, v5.2)', () {
    test('a new signed-in user can self-join as listener', () {
      expect(canSelfJoinListener({'host': const VoiceMember(muted: false, banned: false, present: true)}, 'guest1'), isTrue);
    });

    test('never touches an existing entry - mute/ban tombstones hold', () {
      const tombstone = VoiceMember(muted: true, banned: true, present: false);
      expect(canSelfJoinListener({'kicked': tombstone}, 'kicked'), isFalse);
      const muted = VoiceMember(muted: true, banned: false, present: false);
      expect(canSelfJoinListener({'m': muted}, 'm'), isFalse);
    });

    test('skips dotted ids (nested field-path defense)', () {
      expect(canSelfJoinListener({}, 'mallory.evil'), isFalse);
      expect(canSelfJoinListener({}, 'honest'), isTrue);
    });
  });

  group('enforceLiveModeration', () {
    test('null transport (endpoint unconfigured) skips enforcement', () async {
      await enforceLiveModeration(
        null,
        tableId: 't1',
        targetId: 'u1',
        op: 'kick',
      );
    });

    test('transport failure throws VoiceModerationException', () async {
      final transport = _FakeTransport(fail: true);
      await expectLater(
        enforceLiveModeration(
          transport,
          tableId: 't1',
          targetId: 'u1',
          op: 'kick',
        ),
        throwsA(isA<VoiceModerationException>()),
      );
      expect(transport.calls, [
        {'tableId': 't1', 'targetId': 'u1', 'op': 'kick'},
      ]);
    });

    test('success passes through', () async {
      final transport = _FakeTransport(fail: false);
      await enforceLiveModeration(
        transport,
        tableId: 't1',
        targetId: 'u1',
        op: 'mute',
      );
      expect(transport.calls.single['op'], 'mute');
    });
  });

  group('voiceActionFailureText', () {
    test('moderation failure says saved + live-apply failed', () {
      const e = VoiceModerationException('kick', 'u1');
      expect(voiceActionFailureText(e, 'الطرد'), contains('حُفظ الطرد'));
      expect(voiceActionFailureText(e, 'الكتم'), contains('تعذّر تطبيقه'));
    });

    test('verified permission-denied confidently says nothing saved', () {
      final e = FirebaseException(plugin: 'firestore', code: 'permission-denied');
      expect(voiceActionFailureText(e, 'الكتم'), contains('لم يُحفظ'));
      expect(voiceActionFailureText(e, 'إلغاء الكتم'), contains('إلغاء الكتم'));
    });

    test('generic/network error stays uncertain, never asserts a negative', () {
      final e = StateError('timeout');
      final text = voiceActionFailureText(e, 'الكتم');
      expect(text, contains('تعذّر التأكد'));
      expect(text, isNot(contains('لم يُحفظ')));
    });
  });

  group('parseMembers', () {
    test('skips malformed entries and non-map payloads', () {
      expect(VoiceAuthority.parseMembers(null), isEmpty);
      expect(VoiceAuthority.parseMembers({'members': 'nope'}), isEmpty);
      final parsed = VoiceAuthority.parseMembers({
        'members': {
          'ok': {'muted': false, 'banned': false, 'present': true},
          'bad': {'muted': 'yes'},
        },
      });
      expect(parsed.keys, ['ok']);
      expect(parsed['ok']!.present, isTrue);
    });
  });
}


class _FakeTransport extends VoiceTokenTransport {
  _FakeTransport({required this.fail}) : super(endpoint: 'https://example.invalid/', idToken: () async => 'x');

  final bool fail;
  final List<Map<String, String>> calls = [];

  @override
  Future<void> moderate({
    required String tableId,
    required String targetId,
    required String op,
  }) async {
    calls.add({'tableId': tableId, 'targetId': targetId, 'op': op});
    if (fail) throw StateError('issuer unreachable');
  }
}
