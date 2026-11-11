import 'dart:async';

import 'sound_player.dart';

import 'sound_durations.dart';

/// One clip in a planned, non-overlapping sequence.
class ScheduledClip {
  const ScheduledClip(this.name, this.startMs);
  final String name;
  final int startMs;

  @override
  String toString() => '$name@$startMs';
}

/// Pure planner: clips play one after another and never overlap.
///
/// Consecutive starts are [gapMs] apart (the 200–250 ms "pulse") when the
/// previous clip is shorter than the gap; a longer clip is allowed to finish
/// first (+[tailMs]) before the next one starts.
List<ScheduledClip> planSequence(
  List<String> names, {
  int gapMs = 250,
  int tailMs = 40,
  Map<String, int> durations = soundDurationsMs,
}) {
  final out = <ScheduledClip>[];
  var at = 0;
  for (final name in names) {
    if (!durations.containsKey(name)) {
      continue;
    }
    if (out.isNotEmpty) {
      final prev = out.last;
      final prevDur = durations[prev.name] ?? 0;
      final step = prevDur <= gapMs ? gapMs : prevDur + tailMs;
      at = prev.startMs + step;
    }
    out.add(ScheduledClip(name, at));
  }
  return out;
}

/// Total length of a planned sequence (last start + its duration).
int sequenceLengthMs(List<ScheduledClip> plan) {
  if (plan.isEmpty) return 0;
  final last = plan.last;
  return last.startMs + (soundDurationsMs[last.name] ?? 0);
}

class PresentationCancelled implements Exception {}

class SoundBoard {
  SoundBoard({SoundPlayer Function()? playerFactory, Stopwatch Function()? stopwatchFactory})
    : _playerFactory = playerFactory ?? ManagedSoundPlayer.new,
      _stopwatchFactory = stopwatchFactory ?? Stopwatch.new {
    _a = _playerFactory();
    _b = _playerFactory();
    _loop = _playerFactory();
  }
  final SoundPlayer Function() _playerFactory;
  final Stopwatch Function() _stopwatchFactory;

  late final SoundPlayer _a;
  late final SoundPlayer _b;
  late final SoundPlayer _loop;

  // Sentinel retained so the legacy build script cannot inject playback-only
  // AudioContext writes. Session ownership is in sound_player.dart now.
  Future<void> _initCtx() async {}
  final List<SoundPlayer> _layers = [];
  var _flip = false;
  var _disposed = false;
  int _presentationGeneration = 0;
  int _loopGeneration = 0;
  Completer<void> _cancelPresentation = Completer<void>();

  /// Game sequences are queued so two table updates never overlap.
  Future<void> _queue = Future<void>.value();

  /// Playable event names (asset path without `.mp3`). `boot_unused` is
  /// shipped and never played.
  static final Set<String> events = {
    for (final name in soundDurationsMs.keys)
      if (name != 'boot_unused') name,
  };

  String _asset(String name) => 'sounds/$name.mp3';

  Future<void> loop(String name, {bool repeat = true}) async {
    if (!events.contains(name) || _disposed) {
      return;
    }
    final generation = ++_loopGeneration;
    try {
      await _loop.stop();
      if (_disposed || generation != _loopGeneration) return;
      await _initCtx();
      if (_disposed || generation != _loopGeneration) return;
      await _loop.playAsset(_asset(name), loop: repeat);
    } catch (_) {}
  }

  Future<void> stopLoop() async {
    _loopGeneration++;
    try {
      await _loop.stop();
    } catch (_) {}
  }

  /// Short UI clip, played immediately.
  Future<void> play(String name) async {
    if (!events.contains(name) || _disposed) {
      return;
    }
    final player = _flip ? _b : _a;
    _flip = !_flip;
    try {
      await player.stop();
      await _initCtx();
      await player.playAsset(_asset(name));
    } catch (_) {}
  }

  /// Kept for older call sites: plays the clips in sequence (never layered).
  Future<void> playAll(List<String> names) => playSequence(names);

  /// Runs one game presentation atomically: movement, result, then turn.
  /// Other game presentations cannot start halfway through this callback.
  Future<void> present(Future<void> Function() action) {
    final generation = _presentationGeneration;
    final run = _queue.then((_) async {
      if (_disposed || generation != _presentationGeneration) return;
      await action();
    });
    _queue = run.catchError((_) {});
    return run;
  }

  static bool _isStepSound(String name) =>
      name == 'jk_step1' ||
      name == 'jk_step2' ||
      name == 'jk_step_back1' ||
      name == 'jk_step_back2';

  /// How long playback of [valid] may legitimately take, plus slack for
  /// session negotiation. A native stall must fail fast: an unbounded wait
  /// freezes the whole presentation queue (bots, turn timer, turn tone).
  /// Step clips always occupy one 170ms beat slot (tail clipped at the
  /// window), so long moves never outrun the bound.
  static Duration _boundFor(List<String> valid) {
    var totalMs = 0.0;
    for (var i = 0; i < valid.length; i++) {
      final name = valid[i];
      final clipMs = (soundDurationsMs[name] ?? 1500).toDouble();
      totalMs += _isStepSound(name) ? 170.0 : clipMs;
    }
    return Duration(milliseconds: totalMs.round() + 4000);
  }

  /// Native completion, not a duration estimate, advances the game queue.
  /// A missing completion times out as a failure, never as successful playback.
  Future<void> playNow(List<String> names) async {
    if (_disposed) return;
    final valid = [
      for (final n in names)
        if (events.contains(n)) n,
    ];
    if (valid.isEmpty) return;
    final player = _playerFactory();
    _layers.add(player);
    try {
      if (player is SequenceSoundPlayer) {
        await Future.any([
          player.playAssets([for (final n in valid) _asset(n)]),
          _cancelPresentation.future.then<void>(
            (_) => throw PresentationCancelled(),
          ),
        ]).timeout(_boundFor(valid));
      } else {
        final stepWatch = _stopwatchFactory();
        var stepRunIndex = 0;
        for (var i = 0; i < valid.length; i++) {
          if (_disposed) return;
          final name = valid[i];
          final isStep = _isStepSound(name);
          if (isStep) {
            if (stepRunIndex == 0) {
              stepWatch
                ..reset()
                ..start();
            } else {
              final target = kStepBeatInterval * stepRunIndex;
              final wait = target - stepWatch.elapsed;
              if (wait > Duration.zero) {
                await Future<void>.delayed(wait);
                if (_disposed) return;
              }
            }
            stepRunIndex++;
          } else if (stepRunIndex > 0) {
            final tail = (kStepBeatInterval * stepRunIndex) - stepWatch.elapsed;
            if (tail > Duration.zero) {
              await Future<void>.delayed(tail);
              if (_disposed) return;
            }
            stepRunIndex = 0;
            stepWatch.stop();
          }
          final done = player.completed.first;
          await player.playAsset(_asset(name));
          await Future.any([
            done,
            _cancelPresentation.future.then<void>(
              (_) => throw PresentationCancelled(),
            ),
          ]).timeout(_boundFor([name]));
        }
        if (stepRunIndex > 0 && !_disposed) {
          final tail = (kStepBeatInterval * stepRunIndex) - stepWatch.elapsed;
          if (tail > Duration.zero) {
            await Future<void>.delayed(tail);
          }
        }
      }
    } catch (error) {
      if (!_disposed && error is! PresentationCancelled) {
        SoundDiagnostics.record('sequence', error);
      }
      rethrow;
    } finally {
      _layers.remove(player);
      await player.dispose();
    }
  }

  /// Native playlist moves directly between clips, without artificial gaps.
  Future<void> playSequence(
    List<String> names, {
    Duration gap = const Duration(milliseconds: 250),
  }) => present(() => playNow(names));

  /// Sequential ticks: [sounds] in order, or [sound] repeated [times].
  Future<void> playTicks(
    List<String> sounds, {
    int gapMs = 250,
    String? sound,
    int times = 0,
  }) {
    final list = sound != null && times > 0
        ? [for (var i = 0; i < times; i++) sound]
        : sounds;
    return playSequence(list, gap: Duration(milliseconds: gapMs));
  }

  /// Leaving/backgrounding a table must unblock native-completion waits and
  /// discard stale queued turns, without stopping UI or RTC audio.
  Future<void> cancelPresentations() async {
    _presentationGeneration++;
    final previous = _cancelPresentation;
    _cancelPresentation = Completer<void>();
    if (!previous.isCompleted) previous.complete();
    for (final player in [..._layers]) {
      await player.stop();
    }
  }

  Future<void> dispose() async {
    _disposed = true;
    await cancelPresentations();
    final layers = [..._layers];
    _layers.clear();
    for (final player in layers) {
      await player.dispose();
    }
    await _loop.dispose();
    await _a.dispose();
    await _b.dispose();
  }
}
