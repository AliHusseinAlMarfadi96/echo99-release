import '../game/engine.dart';
import '../game/sound_routing.dart';

/// Movement step ticks play faster as whole clips (user request: faster
/// steps, never truncated). 1.0 leaves a clip untouched; tune here only.
const double stepClipSpeed = 1.5;

/// Per-clip whole-file playback rate for game presentation audio.
double clipPlaybackSpeed(String clip) => switch (clip) {
  'jk_step1' || 'jk_step2' || 'jk_step_back1' || 'jk_step_back2' =>
    stepClipSpeed,
  _ => 1.0,
};

/// A game engine may carry an old global victory clip. Outcome belongs to
/// the listener, once, and must not be duplicated by the presentation layer.
List<String> presentationClips(MatchState? prev, MatchState next, String me) {
  if (next.game == 'echo99') return tableSounds(prev: prev, next: next, me: me);
  final cue = next.cue;
  if (cue == null || cue.nonce == prev?.cue?.nonce) return const [];
  final finished = next.status == 'finished' && prev?.status != 'finished';
  return [
    for (final clip in cue.also)
      if (!finished || (clip != matchWinSound && clip != matchLossSound)) clip,
    if (finished) playerWonMatch(next, me) ? matchWinSound : matchLossSound,
  ];
}
