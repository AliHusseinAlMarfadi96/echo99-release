import '../game/engine.dart';
import '../game/sound_routing.dart';

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
