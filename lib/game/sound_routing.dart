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
const endGameSounds = {matchWinSound, matchLossSound, 'loss1', 'bust99'};

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

/// Every clip a table update should play for [me], in order.
///
/// Point events return exactly one clip. Win/loss end clips only appear when
/// [me] reaches 0 or the match finishes. The cue's stored `also` list is not
/// trusted for point sounds, so a table written by an older build cannot
/// layer laughter on top of a point sound.
List<String> tableSounds({
  required MatchState? prev,
  required MatchState next,
  required String me,
}) {
  if (prev == null) {
    return const [];
  }
  if (next.status == 'finished' && prev.status != 'finished') {
    return [playerWonMatch(next, me) ? matchWinSound : matchLossSound];
  }
  final before = {for (final seat in prev.players) seat.id: seat.points};
  final zeroed = <String>{
    for (final seat in next.players)
      if ((before[seat.id] ?? 0) > 0 && seat.points <= 0) seat.id,
  };
  if (zeroed.contains(me)) {
    return const [matchLossSound];
  }
  final cue = next.cue;
  if (cue == null || cue.nonce == prev.cue?.nonce) {
    return zeroed.isEmpty ? const [] : const [eliminatedSound];
  }
  if (cue.type == 'shuffle') {
    return const ['deal'];
  }
  if (zeroed.isNotEmpty) {
    return const [eliminatedSound];
  }
  final play = next.lastPlay;
  final fresh = play != null && play.nonce == cue.nonce;
  final outcome = fresh ? play.outcome : 'neutral';
  final identity = cue.also.firstWhere(
    identitySounds.contains,
    orElse: () => 'card',
  );
  return [
    playSound(outcome, identity: identity),
    if (fresh && play.redealt) 'deal',
  ];
}
