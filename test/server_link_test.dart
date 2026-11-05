import 'dart:async';

import 'package:echo99/services/server_link.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Firestore answering is enough to be online', () async {
    final result = await reachTableServer(() async => 42);
    expect(result.online, isTrue);
    expect(result.latencyMs, 42);
  });

  test(
    'Firestore failure is the only thing that blocks the online path',
    () async {
      final result = await reachTableServer(
        () async => throw StateError('unavailable'),
      );
      expect(result.online, isFalse);
      expect(result.error, startsWith('firestore/'));
    },
  );

  test('Firestore timeout is reported', () async {
    final result = await reachTableServer(
      () => Completer<int>().future,
      timeout: const Duration(milliseconds: 10),
    );
    expect(result.error, 'firestore/timeout');
  });

  test('voice succeeds on the retry after one LiveKit failure', () async {
    var calls = 0;
    final error = await warmVoiceBestEffort(() async {
      calls += 1;
      if (calls == 1) {
        throw StateError('livekit');
      }
      return null;
    }, retryDelay: Duration.zero);
    expect(error, isNull);
    expect(calls, 2);
  });

  test(
    'voice that keeps failing returns the Arabic note, never throws',
    () async {
      var calls = 0;
      final error = await warmVoiceBestEffort(() async {
        calls += 1;
        throw StateError('livekit');
      }, retryDelay: Duration.zero);
      expect(error, voiceUnavailableNote);
      expect(calls, 2);
    },
  );

  test('voice timeout is retried then reported', () async {
    var calls = 0;
    final error = await warmVoiceBestEffort(
      () {
        calls += 1;
        return Completer<String?>().future;
      },
      timeout: const Duration(milliseconds: 10),
      retryDelay: Duration.zero,
    );
    expect(error, voiceUnavailableNote);
    expect(calls, 2);
  });

  test('a configuration error is not retried', () async {
    var calls = 0;
    final error = await warmVoiceBestEffort(() async {
      calls += 1;
      return 'الصوت غير مهيأ.';
    }, retryDelay: Duration.zero);
    expect(error, 'الصوت غير مهيأ.');
    expect(calls, 1);
  });
}
