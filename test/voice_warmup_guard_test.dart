import 'package:echo99/services/voice_room.dart';
import 'package:flutter_test/flutter_test.dart';

class _RecordingVoice extends VoiceRoom {
  final calls = <String>[];

  @override
  Future<String?> connectVoice({
    required String identity,
    required String displayName,
    required String tableId,
  }) async {
    calls.add(tableId);
    return null;
  }
}

void main() {
  test(
    'warmup never hijacks an active or in-flight table room',
    () async {
      final v = _RecordingVoice();
      v.debugSetActiveRooms(connectingTableId: 'table_99');
      expect(await v.warmup(identity: 'u1', displayName: 'Ali'), isNull);
      expect(v.calls, isEmpty, reason: 'in-flight table connect must win');

      v.debugSetActiveRooms(tableId: 'table_99');
      expect(await v.warmup(identity: 'u1', displayName: 'Ali'), isNull);
      expect(v.calls, isEmpty, reason: 'active table room must not be replaced');

      // Regression: while table_99 is connecting, _tableId may still hold the
      // settled lobby room; the in-flight connect must win the guard.
      v.debugSetActiveRooms(tableId: 'echo99lobby', connectingTableId: 'table_99');
      expect(await v.warmup(identity: 'u1', displayName: 'Ali'), isNull);
      expect(v.calls, isEmpty, reason: 'in-flight table connect beats stale lobby state');
    },
  );

  test('warmup joins the lobby when idle or already in the lobby', () async {
    final v = _RecordingVoice();
    expect(await v.warmup(identity: 'u1', displayName: 'Ali'), isNull);
    expect(v.calls, ['echo99lobby']);

    final v2 = _RecordingVoice();
    v2.debugSetActiveRooms(tableId: 'echo99lobby');
    await v2.warmup(identity: 'u1', displayName: 'Ali');
    expect(v2.calls, ['echo99lobby']);
  });
}
