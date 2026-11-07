import 'engine.dart';

/// Asset names (`assets/sounds/NAME.mp3`) and the zip file each one is.
///
/// Exact/cross 33 or 66 never resets the pile — only short point clips.
/// penalty    = «صوت تخطي رقم 33 أو 66 وخسارة نقطة» (0.78 s, short ding)
/// gain       = «صوت وصول 33 أو 66 بالضبط والحصول على نقطة» (1.78 s)
/// exact99    = «صوت وصول 99 بالضبط والفوز بالجولة» (1.59 s, tonal, no applause)
/// eliminated = «صوت خروج لاعب من مجموعة إذا وصل نقاط صفر» (0.60 s, falling tone)
/// applause   = «تصفيق» (6.3 s, clapping over music) — match winner only
/// loss2      = «صوت خسارة2» (4.2 s, laughter + crash) — match loser only
///
/// «خسارة واحد» (loss1, laughter) and «صوت تخطيط 99 أو خسارة العضو»
/// (bust99, crash/glass attack) are never played for a point loss.
const pointLossSound = 'penalty';
const pointGainSound = 'gain';
const exact99Sound = 'exact99';
const eliminatedSound = 'eliminated';
const matchWinSound = 'applause';
const matchLossSound = 'loss2';

/// Clips that may only sound when a player reaches 0 or the match ends.
const endGameSounds = {matchWinSound, matchLossSound, 'loss1'};

/// Card identity clips used for a play with no point change.
const identitySounds = {'jack', 'three', 'reverse', 'ordinary', 'card'};

/// The single clip for one card play when nobody reached 0.
String playSound(String outcome, {String identity = 'card'}) {
  switch (outcome) {
    case 'band':
    case 'bust':
      return pointLossSound;
    case 'exact33':
    case 'exact66':
      return pointGainSound;
    case 'exact99':
      return exact99Sound;
    default:
      return identitySounds.contains(identity) ? identity : 'card';
  }
}

/// Per-listener round outcome, then a separate final-match outcome.
List<String> tableSounds({
  required MatchState? prev,
  required MatchState next,
  required String me,
}) {
  if (prev == null) return const [];
  final cue = next.cue;
  if (cue == null || cue.nonce == prev.cue?.nonce) return const [];
  final play = next.lastPlay;
  final fresh = play != null && play.nonce == cue.nonce;
  final before = {for (final seat in prev.players) seat.id: seat.points};
  final lost = next.players.any(
    (s) => s.id == me && s.points < (before[me] ?? s.points),
  );
  final actor = prev.current?.id == me;
  final clips = <String>[];
  if (fresh && (play.outcome == 'exact99' || play.outcome == 'bust')) {
    // Original rules identify who loses points. The winner's named metal
    // and the loser's named glass are round clips, not match celebration.
    if (lost) {
      clips.add('bust99');
    } else if (play.outcome == 'exact99' && actor ||
        play.outcome == 'bust' && !actor) {
      clips.add(exact99Sound);
    }
  } else if (cue.type == 'shuffle') {
    clips.add('deal');
  } else {
    final identity = cue.also.firstWhere(
      identitySounds.contains,
      orElse: () => 'card',
    );
    clips.add(playSound(fresh ? play.outcome : 'neutral', identity: identity));
  }
  final ended = next.status == 'finished' && prev.status != 'finished';
  final zeroedMe = next.players.any(
    (s) => s.id == me && s.points <= 0 && (before[me] ?? 0) > 0,
  );
  if (ended) {
    clips.add(playerWonMatch(next, me) ? matchWinSound : matchLossSound);
  } else if (zeroedMe) {
    clips.add(matchLossSound);
  } else if (next.players.any(
    (s) => s.points <= 0 && (before[s.id] ?? 0) > 0,
  )) {
    clips.add(eliminatedSound);
  }
  if (fresh && play.redealt && !ended) clips.add('deal');
  return clips;
}
