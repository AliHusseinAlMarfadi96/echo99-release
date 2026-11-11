import 'dart:async';

import 'package:echo99/services/sound_player.dart';
import 'package:echo99/services/sounds.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

/// Stopwatch driven by the fakeAsync clock so wall-clock pacing in the
/// fallback playback path can be tested deterministically.
class _FakeStopwatch implements Stopwatch {
  _FakeStopwatch(this._now);
  final DateTime Function() _now;
  DateTime? _start;
  Duration _accumulated = Duration.zero;

  @override
  Duration get elapsed =>
      _accumulated +
      (_start == null ? Duration.zero : _now().difference(_start!));

  @override
  int get elapsedMicroseconds => elapsed.inMicroseconds;
  @override
  int get elapsedMilliseconds => elapsed.inMilliseconds;
  @override
  int get elapsedTicks => elapsed.inMicroseconds * 60;
  @override
  int get frequency => 1000000 * 60;
  @override
  bool get isRunning => _start != null;

  @override
  void start() {
    _start ??= _now();
  }

  @override
  void stop() {
    _accumulated = elapsed;
    _start = null;
  }

  @override
  void reset() {
    _accumulated = Duration.zero;
    _start = isRunning ? _now() : null;
  }
}

/// Records each clip's start time and completes it after its duration,
/// all on the fakeAsync clock. Implements only [SoundPlayer] so the board
/// takes the per-clip fallback path (where the pacing loop lives).
class _TimedFakePlayer implements SoundPlayer {
  _TimedFakePlayer({
    required this.clockMs,
    required this.clipDurationsMs,
    required this.startLog,
  });

  final int Function() clockMs;
  final Map<String, int> clipDurationsMs;
  final List<String> startLog;
  final StreamController<void> _completed =
      StreamController<void>.broadcast();

  @override
  Stream<void> get completed => _completed.stream;

  @override
  Future<void> playAsset(String path, {bool loop = false}) async {
    startLog.add('$path@${clockMs()}ms');
    final durationMs = clipDurationsMs[path] ?? 100;
    Future<void>.delayed(Duration(milliseconds: durationMs), () {
      if (!_completed.isClosed) _completed.add(null);
    });
  }

  @override
  Future<void> stop() async {}

  @override
  Future<void> dispose() async {
    await _completed.close();
  }
}

void main() {
  for (final stepClip in <String>['jk_step1', 'jk_step2']) {
    test(
      '$stepClip paces at exact 240ms starts and delays the result clip '
      'until the last step completes (fallback path)',
      () {
        fakeAsync((async) {
          final origin = async.getClock(DateTime.utc(2026, 1, 1)).now();
          int elapsedMs() => async
              .getClock(DateTime.utc(2026, 1, 1))
              .now()
              .difference(origin)
              .inMilliseconds;

          final clipDurations = <String, int>{
            'sounds/jk_step1.mp3': 216,
            'sounds/jk_step2.mp3': 120,
            'sounds/jk_kill.mp3': 1032,
          };
          final startLog = <String>[];
          final board = SoundBoard(
            playerFactory: () => _TimedFakePlayer(
              clockMs: elapsedMs,
              clipDurationsMs: clipDurations,
              startLog: startLog,
            ),
            stopwatchFactory: () => _FakeStopwatch(
              () => async.getClock(DateTime.utc(2026, 1, 1)).now(),
            ),
          );

          var finished = false;
          board
              .playNow(<String>[
                stepClip,
                stepClip,
                stepClip,
                stepClip,
                'jk_kill',
              ])
              .then((_) => finished = true);

          // 4 steps x 240ms + jk_kill (1032ms) = 1992ms total.
          async.elapse(const Duration(milliseconds: 959));
          expect(
            finished,
            isFalse,
            reason: 'presentation must not finish before the 4-step run',
          );
          expect(
            startLog,
            equals(<String>[
              'sounds/$stepClip.mp3@0ms',
              'sounds/$stepClip.mp3@240ms',
              'sounds/$stepClip.mp3@480ms',
              'sounds/$stepClip.mp3@720ms',
            ]),
            reason: '$stepClip must fire at exact 240ms start-to-start',
          );

          async.elapse(const Duration(milliseconds: 1));
          expect(
            startLog.last,
            'sounds/jk_kill.mp3@960ms',
            reason: 'result clip starts only after the last step slot ends',
          );
          expect(finished, isFalse, reason: 'jk_kill still playing');

          async.elapse(const Duration(milliseconds: 1032));
          expect(finished, isTrue);
        });
      },
    );
  }

  test('a late step completion never lets the next step or result overlap', () {
    fakeAsync((async) {
      final origin = async.getClock(DateTime.utc(2026, 1, 1)).now();
      int elapsedMs() => async
          .getClock(DateTime.utc(2026, 1, 1))
          .now()
          .difference(origin)
          .inMilliseconds;

      // First step takes 500ms to complete (late); the run must not stack.
      final clipDurations = <String, int>{
        'sounds/jk_step1.mp3': 500,
        'sounds/jk_kill.mp3': 1032,
      };
      final startLog = <String>[];
      final board = SoundBoard(
        playerFactory: () => _TimedFakePlayer(
          clockMs: elapsedMs,
          clipDurationsMs: clipDurations,
          startLog: startLog,
        ),
        stopwatchFactory: () => _FakeStopwatch(
          () => async.getClock(DateTime.utc(2026, 1, 1)).now(),
        ),
      );

      var finished = false;
      board
          .playNow(<String>['jk_step1', 'jk_step1', 'jk_kill'])
          .then((_) => finished = true);

      async.elapse(const Duration(milliseconds: 500));
      // Step 2 starts immediately once the late step 1 completes
      // (its 240ms slot already passed; pacing never rewinds time).
      expect(startLog, <String>[
        'sounds/jk_step1.mp3@0ms',
        'sounds/jk_step1.mp3@500ms',
      ]);

      // Tail: run window = 2 x 240ms = 480ms, already passed, so jk_kill
      // follows step 2's completion (500 + 500 = 1000ms).
      async.elapse(const Duration(milliseconds: 499));
      expect(startLog.length, 2);
      async.elapse(const Duration(milliseconds: 1));
      expect(startLog.last, 'sounds/jk_kill.mp3@1000ms');
      async.elapse(const Duration(milliseconds: 1032));
      expect(finished, isTrue);
    });
  });
}
