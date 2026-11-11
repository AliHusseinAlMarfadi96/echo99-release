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
/// Honors the requested clip tail (completion at clipEnd when shorter);
/// [stall] simulates a native completion signal arriving late regardless.
class _FakeDriver implements StepClipDriver {
  _FakeDriver({
    required this.clockMs,
    required this.clipDurationMs,
    this.stall = false,
    this.ipcMs = 0,
    this.completionLatencyMs = 0,
  });
  final int Function() clockMs;
  final int clipDurationMs;
  final bool stall;

  /// Simulated platform-channel cost of a pause/seek call.
  final int ipcMs;

  /// Simulated delay of the native playback-completed signal past the
  /// (clipped) clip end.
  final int completionLatencyMs;
  final List<String> events = <String>[];
  Duration? lastClipEnd;

  @override
  Future<void> pause() async {
    events.add('pause@${clockMs()}ms');
    await Future<void>.delayed(Duration(milliseconds: ipcMs));
  }

  @override
  Future<void> setClip(String asset, {Duration? clipEnd}) async {
    lastClipEnd = clipEnd;
    events.add('setClip:$asset@${clockMs()}ms');
  }

  @override
  Future<void> seek(Duration position) async {
    events.add('seek@${clockMs()}ms');
    await Future<void>.delayed(Duration(milliseconds: ipcMs));
  }

  @override
  Future<void> play() async {
    events.add('play@${clockMs()}ms');
    var durationMs = clipDurationMs;
    final end = lastClipEnd;
    if (!stall && end != null && end.inMilliseconds < durationMs) {
      durationMs = end.inMilliseconds;
    }
    await Future<void>.delayed(
      Duration(milliseconds: durationMs + completionLatencyMs),
    );
  }
}

void main() {
  test(
    'production paced step run fires plays at exact 170ms starts and holds the run window',
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

        async.elapse(const Duration(milliseconds: 679));
        expect(finished, isFalse, reason: 'run window is 4 x 170ms = 680ms');
        expect(
          driver.events.where((e) => e.startsWith('play@')),
          equals(<String>['play@0ms', 'play@170ms', 'play@340ms', 'play@510ms']),
        );
        // The 216ms clip is clipped at kStepClipEnd (140ms), inside the
        // 170ms beat window, leaving headroom for completion + IPC.
        expect(driver.lastClipEnd, kStepClipEnd);
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

  test(
    '140ms clip margin absorbs simulated completion + IPC latency: cadence stays uniform',
    () {
      fakeAsync((async) {
        final origin = async.getClock(DateTime.utc(2026, 1, 1)).now();
        int elapsedMs() => async
            .getClock(DateTime.utc(2026, 1, 1))
            .now()
            .difference(origin)
            .inMilliseconds;

        // Simulated iOS overhead: the play() future resolves 8ms after the
        // clipped end (completion notification), and each pause/seek costs
        // 6ms of platform-channel time. Per step that is 140 + 8 + 6 + 6 =
        // 160ms < 170ms, so the grid must absorb it instead of compounding.
        final driver = _FakeDriver(
          clockMs: elapsedMs,
          clipDurationMs: 216,
          ipcMs: 6,
          completionLatencyMs: 8,
        );
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

        async.elapse(const Duration(milliseconds: 1200));
        expect(finished, isTrue);

        final starts = driver.events
            .where((e) => e.startsWith('play@'))
            .map((e) => int.parse(e.substring(5, e.length - 2)))
            .toList();
        expect(starts.length, 4);
        // After the first step, every start waits out its grid boundary and
        // then pays only the pause/seek IPC, so consecutive starts are
        // exactly one beat apart: uniform 170ms cadence under latency.
        // (With clipEnd == 170ms the same latency would make every step
        // cost 170 + 8 + 12 = 190ms with no grid room left, so the cadence
        // itself would slow to 190ms per step; the margin prevents that.)
        for (var i = 2; i < starts.length; i++) {
          expect(
            starts[i] - starts[i - 1],
            kStepBeatInterval.inMilliseconds,
            reason: 'uniform cadence under simulated latency',
          );
        }
        // The first interval carries the pause/seek IPC past the grid
        // boundary; it must never exceed beat + 2 * ipc.
        expect(
          starts[1] - starts[0],
          lessThanOrEqualTo(kStepBeatInterval.inMilliseconds + 12),
        );
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

      // stall: the native completion signal arrives at 500ms even though the
      // clip is windowed at 170ms (abnormal; must never overlap).
      final driver = _FakeDriver(
        clockMs: elapsedMs,
        clipDurationMs: 500,
        stall: true,
      );
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
