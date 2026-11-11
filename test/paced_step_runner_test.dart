
import 'package:echo99/services/sound_player.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

/// Stopwatch driven by the fakeAsync clock.
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

/// Fake driver: play() blocks for the clip duration on the fake clock,
/// mimicking just_audio's play() completing only at clip end or stop.
class _FakeDriver implements StepClipDriver {
  _FakeDriver({required this.clockMs, required this.clipDurationMs});
  final int Function() clockMs;
  final int clipDurationMs;
  final List<String> events = <String>[];

  @override
  Future<void> pause() async {
    events.add('pause@${clockMs()}ms');
  }

  @override
  Future<void> setAsset(String asset) async {
    events.add('setAsset:$asset@${clockMs()}ms');
  }

  @override
  Future<void> seek(Duration position) async {
    events.add('seek@${clockMs()}ms');
  }

  @override
  Future<void> play() async {
    events.add('play@${clockMs()}ms');
    await Future<void>.delayed(Duration(milliseconds: clipDurationMs));
  }
}

void main() {
  test(
    'production paced step run fires plays at exact 240ms starts and holds the run window',
    () {
      fakeAsync((async) {
        final origin = async.getClock(DateTime.utc(2026, 1, 1)).now();
        int elapsedMs() => async
            .getClock(DateTime.utc(2026, 1, 1))
            .now()
            .difference(origin)
            .inMilliseconds;

        final driver = _FakeDriver(clockMs: elapsedMs, clipDurationMs: 216);
        final runner = PacedStepRunner(
          driver: driver,
          stopwatchFactory: () => _FakeStopwatch(
            () => async.getClock(DateTime.utc(2026, 1, 1)).now(),
          ),
        );

        var finished = false;
        runner
            .run(
              assetPath: 'sounds/jk_step1.mp3',
              stepCount: 4,
              cancelled: () => false,
            )
            .then((_) => finished = true);

        async.elapse(const Duration(milliseconds: 959));
        expect(finished, isFalse, reason: 'run window is 4 x 240ms = 960ms');
        expect(
          driver.events.where((e) => e.startsWith('play@')),
          equals(<String>['play@0ms', 'play@240ms', 'play@480ms', 'play@720ms']),
        );
        // Each step after the first rewinds to the clip start before playing.
        expect(
          driver.events.where((e) => e.startsWith('seek@')).length,
          3,
        );

        async.elapse(const Duration(milliseconds: 1));
        expect(finished, isTrue);
      });
    },
  );

  test('a late clip completion never overlaps the next step; no rewind of time', () {
    fakeAsync((async) {
      final origin = async.getClock(DateTime.utc(2026, 1, 1)).now();
      int elapsedMs() => async
          .getClock(DateTime.utc(2026, 1, 1))
          .now()
          .difference(origin)
          .inMilliseconds;

      final driver = _FakeDriver(clockMs: elapsedMs, clipDurationMs: 500);
      final runner = PacedStepRunner(
        driver: driver,
        stopwatchFactory: () => _FakeStopwatch(
          () => async.getClock(DateTime.utc(2026, 1, 1)).now(),
        ),
      );

      var finished = false;
      runner
          .run(
            assetPath: 'sounds/jk_step1.mp3',
            stepCount: 2,
            cancelled: () => false,
          )
          .then((_) => finished = true);

      async.elapse(const Duration(milliseconds: 1000));
      expect(
        driver.events.where((e) => e.startsWith('play@')),
        equals(<String>['play@0ms', 'play@500ms']),
        reason: 'the second step starts only after the late first clip ends',
      );
      expect(finished, isTrue, reason: 'no tail wait once the window passed');
    });
  });

  test('cancellation aborts the run before the next play', () {
    fakeAsync((async) {
      final origin = async.getClock(DateTime.utc(2026, 1, 1)).now();
      int elapsedMs() => async
          .getClock(DateTime.utc(2026, 1, 1))
          .now()
          .difference(origin)
          .inMilliseconds;

      final driver = _FakeDriver(clockMs: elapsedMs, clipDurationMs: 216);
      final runner = PacedStepRunner(
        driver: driver,
        stopwatchFactory: () => _FakeStopwatch(
          () => async.getClock(DateTime.utc(2026, 1, 1)).now(),
        ),
      );

      var finished = false;
      runner
          .run(
            assetPath: 'sounds/jk_step1.mp3',
            stepCount: 4,
            // Cancel once two plays have started (e.g. stop()/dispose()).
            cancelled: () =>
                driver.events.where((e) => e.startsWith('play@')).length >= 2,
          )
          .then((_) => finished = true);

      async.elapse(const Duration(milliseconds: 2000));
      final plays = driver.events.where((e) => e.startsWith('play@')).length;
      expect(finished, isTrue);
      expect(plays, 2, reason: 'no further steps play after cancellation');
    });
  });
}
