import 'dart:async';

import 'package:echo99/services/startup_audio.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'boot and login reuse one clip; repeated startOnce never replays',
    () async {
      final events = <String>[];
      final startup = StartupAudio(
        start: () async {
          events.add('start');
        },
        stop: () async {
          events.add('stop');
        },
      );
      await startup.startOnce();
      await startup.connecting();
      await startup.startOnce();
      expect(events, ['start']);
      await startup.finish();
      await startup.startOnce();
      expect(events, ['start', 'stop']);
      await startup.connecting();
      expect(events, ['start', 'stop', 'start']);
      await startup.close();
      await startup.connecting();
      expect(events, ['start', 'stop', 'start', 'stop']);
    },
  );
  test(
    'background stop waits for pending start, so late load cannot revive clip',
    () async {
      final events = <String>[];
      final loading = Completer<void>();
      final startup = StartupAudio(
        start: () async {
          events.add('start');
          await loading.future;
        },
        stop: () async {
          events.add('stop');
        },
      );
      final start = startup.startOnce();
      await Future<void>.delayed(Duration.zero);
      final stop = startup.finish();
      expect(events, ['start']);
      loading.complete();
      await start;
      await stop;
      expect(events, ['start', 'stop']);
    },
  );
}
