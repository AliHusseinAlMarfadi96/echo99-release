import 'dart:async';

import 'package:audioplayers/audioplayers.dart';

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

class SoundBoard {
  final AudioPlayer _a = AudioPlayer();
  final AudioPlayer _b = AudioPlayer();
  final AudioPlayer _loop = AudioPlayer();
  final List<AudioPlayer> _layers = [];
  var _flip = false;
  var _disposed = false;

  /// Game sequences are queued so two table updates never overlap.
  Future<void> _queue = Future<void>.value();
  int _queuedUntil = 0;

  /// Playable event names (asset path without `.mp3`). `boot_unused` is
  /// shipped and never played.
  static final Set<String> events = {
    for (final name in soundDurationsMs.keys)
      if (name != 'boot_unused') name,
  };

  String _asset(String name) => 'sounds/$name.mp3';

  Future<void> loop(String name) async {
    if (!events.contains(name)) {
      return;
    }
    try {
      await _loop.setReleaseMode(ReleaseMode.loop);
      await _loop.setVolume(1);
      await _loop.stop();
      await _loop.play(AssetSource(_asset(name)));
    } catch (_) {}
  }

  Future<void> stopLoop() async {
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
      await player.play(AssetSource(_asset(name)));
    } catch (_) {}
  }

  /// Kept for older call sites: plays the clips in sequence (never layered).
  Future<void> playAll(List<String> names) => playSequence(names);

  Future<void> _fire(String name) async {
    if (_disposed) return;
    final player = AudioPlayer();
    _layers.add(player);
    player.onPlayerComplete.listen((_) {
      _layers.remove(player);
      unawaited(player.dispose());
    });
    try {
      await player.play(AssetSource(_asset(name)));
    } catch (_) {}
  }

  /// Plays clips one after another without overlap (see [planSequence]).
  /// A new sequence waits for the previous one to finish.
  Future<void> playSequence(
    List<String> names, {
    Duration gap = const Duration(milliseconds: 250),
  }) {
    final plan = planSequence([
      for (final n in names)
        if (events.contains(n)) n,
    ], gapMs: gap.inMilliseconds);
    if (plan.isEmpty) {
      return Future<void>.value();
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    // Never let a backlog grow beyond a few seconds: drop stale waiting.
    if (_queuedUntil - now > 6000) {
      _queue = Future<void>.value();
      _queuedUntil = now;
    }
    final length = sequenceLengthMs(plan);
    _queuedUntil = (_queuedUntil > now ? _queuedUntil : now) + length + 60;
    final run = _queue.then((_) async {
      final start = DateTime.now().millisecondsSinceEpoch;
      for (final clip in plan) {
        final wait =
            start + clip.startMs - DateTime.now().millisecondsSinceEpoch;
        if (wait > 0) {
          await Future<void>.delayed(Duration(milliseconds: wait));
        }
        unawaited(_fire(clip.name));
      }
      final last = plan.last;
      final tail =
          start +
          last.startMs +
          (soundDurationsMs[last.name] ?? 0) -
          DateTime.now().millisecondsSinceEpoch;
      if (tail > 0) {
        await Future<void>.delayed(Duration(milliseconds: tail + 40));
      }
    });
    _queue = run.catchError((_) {});
    return run;
  }

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

  Future<void> dispose() async {
    _disposed = true;
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
