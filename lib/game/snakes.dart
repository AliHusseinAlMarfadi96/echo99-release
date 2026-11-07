import 'dart:math';

import 'engine.dart';

/// Snakes and Ladders: squares 1–100, every player starts on 0 (off-board).
/// A roll that would pass 100 is wasted; exactly 100 wins.
const snakesGoal = 100;

/// Ladders: bottom → top.
const snakesLadders = <int, int>{
  4: 14,
  9: 31,
  20: 38,
  28: 84,
  40: 59,
  51: 67,
  63: 81,
  71: 91,
};

/// Snakes: head → tail.
const snakesSnakes = <int, int>{
  17: 7,
  54: 34,
  62: 19,
  64: 60,
  87: 24,
  93: 73,
  95: 75,
  98: 79,
};

const snakesCountError = 'السلم والثعبان من 2 إلى 6 لاعبين';

/// Snakes & Ladders zip: «صوت بداية اللعبة», «صوت رمية نرد», «صوت حركة نرد»,
/// «صوت سعود السلم» (ladder), «صوت الثعبان».
const snakesStartSound = 'snakes/game_started';
const snakesRollSound = 'snakes/dice_roll';
const snakesDingSound = 'snakes/step';
const snakesLadderSound = 'snakes/ladder';
const snakesSnakeSound = 'snakes/snake';

class SnakesOutcome {
  const SnakesOutcome({
    required this.from,
    required this.roll,
    required this.landed,
    required this.to,
    required this.jump,
  });

  final int from;
  final int roll;

  /// Square reached by the dice before any ladder / snake.
  final int landed;
  final int to;

  /// ladder | snake | over | ''
  final String jump;

  bool get won => to == snakesGoal;
}

/// Pure movement rule.
SnakesOutcome snakesMove(int from, int roll) {
  final landed = from + roll;
  if (landed > snakesGoal) {
    return SnakesOutcome(
      from: from,
      roll: roll,
      landed: from,
      to: from,
      jump: 'over',
    );
  }
  final ladder = snakesLadders[landed];
  if (ladder != null) {
    return SnakesOutcome(
      from: from,
      roll: roll,
      landed: landed,
      to: ladder,
      jump: 'ladder',
    );
  }
  final snake = snakesSnakes[landed];
  if (snake != null) {
    return SnakesOutcome(
      from: from,
      roll: roll,
      landed: landed,
      to: snake,
      jump: 'snake',
    );
  }
  return SnakesOutcome(
    from: from,
    roll: roll,
    landed: landed,
    to: landed,
    jump: '',
  );
}

/// Sound clips for one roll: the dice roll once, one step clip per square
/// actually moved (250 ms pulse), then — right after the last step — the
/// ladder-up or snake-down clip.
List<String> snakesSounds(SnakesOutcome outcome) => [
  snakesRollSound,
  for (var i = 0; i < outcome.landed - outcome.from; i++) snakesDingSound,
  if (outcome.jump == 'ladder') snakesLadderSound,
  if (outcome.jump == 'snake') snakesSnakeSound,
];

Map<String, int> snakesPositions(MatchState state) {
  final raw = state.board['positions'];
  final out = <String, int>{};
  if (raw is Map) {
    raw.forEach((k, v) => out['$k'] = (v as num).toInt());
  }
  return out;
}

EngineResult startSnakes(MatchState state, int nowMillis) {
  final count = state.players.length;
  if (count < 2 || count > 6) {
    return EngineResult(state, snakesCountError);
  }
  var host = state.players.indexWhere((s) => s.id == state.hostId);
  if (host < 0) {
    host = 0;
  }
  final nonce = state.nonce + 1;
  return EngineResult(
    state.copyWith(
      players: [for (final s in state.players) s.copyWith(points: 1)],
      status: 'playing',
      pile: 0,
      lastCard: null,
      turnIndex: host,
      direction: 1,
      deck: const [],
      discard: const [],
      hands: const {},
      lastPlay: null,
      cue: SoundCue(
        type: 'snakes',
        nonce: nonce,
        also: const [snakesStartSound],
      ),
      winnerId: null,
      nonce: nonce,
      turnStartedAt: nowMillis,
      board: {
        'positions': {for (final s in state.players) s.id: 0},
        'text': 'بدأت لعبة السلم والثعبان',
      },
    ),
  );
}

/// Applies a roll. [roll] must come from the server-side transaction
/// ([rollDie]); clients never choose it.
EngineResult rollSnakes(
  MatchState state, {
  required String playerId,
  required int roll,
  required int nowMillis,
}) {
  if (state.status != 'playing' || state.game != gameSnakes) {
    return EngineResult(state, 'المباراة ليست جارية');
  }
  final seat = state.current;
  if (seat == null || seat.id != playerId) {
    return EngineResult(state, 'ليس دورك');
  }
  if (roll < 1 || roll > 6) {
    return EngineResult(state, 'رمية غير صالحة');
  }
  final positions = snakesPositions(state);
  final outcome = snakesMove(positions[playerId] ?? 0, roll);
  positions[playerId] = outcome.to;
  final nonce = state.nonce + 1;
  var text = '${seat.name} رمى $roll';
  if (outcome.jump == 'over') {
    text +=
        ' ويحتاج ${snakesGoal - outcome.from} بالضبط، بقي في ${outcome.from}';
  } else if (outcome.jump == 'ladder') {
    text += '، وصل ${outcome.landed} وصعد السلم إلى ${outcome.to}';
  } else if (outcome.jump == 'snake') {
    text += '، وصل ${outcome.landed} ونزل مع الثعبان إلى ${outcome.to}';
  } else {
    text += '، انتقل إلى ${outcome.to}';
  }
  final board = {
    'positions': positions,
    'lastRoll': roll,
    'lastFrom': outcome.from,
    'lastTo': outcome.to,
    'jump': outcome.jump,
    'text': outcome.won ? '$text. فاز ${seat.name}' : text,
  };
  final cue = SoundCue(
    type: 'snakes',
    nonce: nonce,
    also: snakesSounds(outcome),
  );
  if (outcome.won) {
    return EngineResult(
      state.copyWith(
        status: 'finished',
        winnerId: playerId,
        cue: cue,
        nonce: nonce,
        turnStartedAt: nowMillis,
        board: board,
      ),
    );
  }
  return EngineResult(
    state.copyWith(
      turnIndex: (state.turnIndex + 1) % state.players.length,
      cue: cue,
      nonce: nonce,
      turnStartedAt: nowMillis,
      board: board,
    ),
  );
}

int rollDie(Random random) => random.nextInt(6) + 1;

String snakesPositionsText(MatchState state) {
  final positions = snakesPositions(state);
  if (positions.isEmpty) {
    return 'لم تبدأ اللعبة بعد';
  }
  return [
    for (final seat in state.players)
      '${seat.name}: ${snakesSquareText(positions[seat.id] ?? 0)}',
  ].join('، ');
}

/// «الخانة 28، أسفل سلم إلى 84» etc. for one square.
String snakesSquareText(int square) {
  if (square <= 0) return 'خارج اللوحة';
  if (square >= snakesGoal) return 'الخانة 100، النهاية';
  return 'الخانة $square';
}

String snakesOwnText(MatchState state, String me) {
  final pos = snakesPositions(state)[me];
  if (pos == null) {
    return 'لست لاعباً في هذه الطاولة';
  }
  return 'أنت في المربع $pos';
}
