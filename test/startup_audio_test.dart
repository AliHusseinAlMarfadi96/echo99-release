import 'dart:async';

import 'package:echo99/services/startup_audio.dart';
import 'package:fake_async/fake_async.dart';
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
    'finish interrupts a pending start immediately; a late load cannot revive the clip',
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
      // New contract: finish() never waits behind a still-playing/loading
      // start(); it stops right away. Protection against a late load
      // reviving the clip lives in SoundBoard's loop generation guard.
      await startup.finish();
      expect(events, ['start', 'stop']);
      loading.complete();
      await start;
      expect(events, ['start', 'stop']);
    },
  );

  group('StartupAudio non-blocking start & immediate finish', () {
    test(
      'finish() interrupts 30s ambient playback immediately and orders connected after stop',
      () {
        fakeAsync((async) {
          final origin = async.getClock(DateTime.utc(2026, 1, 1)).now();
          int nowMs() => async
              .getClock(DateTime.utc(2026, 1, 1))
              .now()
              .difference(origin)
              .inMilliseconds;

          final events = <String>[];
          Completer<void>? ambientPlayback;
          Timer? naturalEndTimer;

          final startup = StartupAudio(
            start: () {
              events.add('ambient:start@${nowMs()}ms');
              ambientPlayback = Completer<void>();
              // Mimics just_audio: play() completes only after the full
              // clip (30s) or when stop() is called.
              naturalEndTimer = Timer(const Duration(seconds: 30), () {
                if (!(ambientPlayback?.isCompleted ?? true)) {
                  events.add('ambient:natural_end@${nowMs()}ms');
                  ambientPlayback!.complete();
                }
              });
              return ambientPlayback!.future;
            },
            stop: () async {
              events.add('ambient:stop_called@${nowMs()}ms');
              naturalEndTimer?.cancel();
              await Future<void>.delayed(const Duration(milliseconds: 10));
              if (!(ambientPlayback?.isCompleted ?? true)) {
                ambientPlayback!.complete();
              }
              events.add('ambient:stopped@${nowMs()}ms');
            },
          );

          Future<void> runLinkSimulation() async {
            await startup.connecting();
            events.add('connecting:returned@${nowMs()}ms');
            await Future<void>.delayed(const Duration(milliseconds: 2200));
            // Simulates the server probe finishing at 3500ms total.
            await Future<void>.delayed(const Duration(milliseconds: 1300));
            await startup.finish();
            events.add('connected:play@${nowMs()}ms');
          }

          var linkCompleted = false;
          runLinkSimulation().then((_) => linkCompleted = true);

          // connecting() must return at 0ms, not after the 30s clip.
          async.flushMicrotasks();
          expect(events, contains('ambient:start@0ms'));
          expect(events, contains('connecting:returned@0ms'));

          async.elapse(const Duration(milliseconds: 3510));
          expect(linkCompleted, isTrue);
          expect(
            events,
            equals(<String>[
              'ambient:start@0ms',
              'connecting:returned@0ms',
              'ambient:stop_called@3500ms',
              'ambient:stopped@3510ms',
              'connected:play@3510ms',
            ]),
            reason:
                'finish() must stop ambient at 3500ms without waiting for '
                'the 30s natural end, and connected must play only after '
                'ambient:stopped',
          );
        });
      },
    );

    test('startOnce() is idempotent and finish() while inactive is a no-op',
        () async {
      var starts = 0;
      var stops = 0;
      final startup = StartupAudio(
        start: () async => starts++,
        stop: () async => stops++,
      );

      await startup.startOnce();
      await startup.startOnce();
      await startup.connecting();
      expect(starts, equals(1));

      await startup.finish();
      await startup.finish();
      expect(stops, equals(1));

      await startup.close();
      await startup.connecting();
      expect(starts, equals(1));
    });
  });
}
