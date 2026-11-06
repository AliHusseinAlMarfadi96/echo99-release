import 'dart:math';

import 'rules.dart';
import 'sound_routing.dart';

class Seat {
  const Seat({
    required this.id,
    required this.name,
    required this.points,
    required this.isBot,
    this.reconnectingSince = 0,
    this.micMuted = false,
    this.chatBlocked = false,
  });

  final String id;
  final String name;
  final int points;
  final bool isBot;

  /// Epoch millis when this human's socket dropped; 0 = connected.
  /// While non-zero the seat shows «Reconnecting...» and keeps its score.
  final int reconnectingSince;

  /// Host mute: clients must block local unmute and disable this identity's remote audio.
  final bool micMuted;

  /// Host block-chat: send path rejects while true.
  final bool chatBlocked;

  bool get reconnecting => reconnectingSince > 0;

  Seat copyWith({
    String? id,
    String? name,
    int? points,
    bool? isBot,
    int? reconnectingSince,
    bool? micMuted,
    bool? chatBlocked,
  }) {
    return Seat(
      id: id ?? this.id,
      name: name ?? this.name,
      points: points ?? this.points,
      isBot: isBot ?? this.isBot,
      reconnectingSince: reconnectingSince ?? this.reconnectingSince,
      micMuted: micMuted ?? this.micMuted,
      chatBlocked: chatBlocked ?? this.chatBlocked,
    );
  }

  Map<String, dynamic> toMap() => {
    'id': id,
    'name': name,
    'points': points,
    'isBot': isBot,
    'reconnectingSince': reconnectingSince,
    'micMuted': micMuted,
    'chatBlocked': chatBlocked,
  };

  static Seat fromMap(Map<dynamic, dynamic> map) {
    return Seat(
      id: '${map['id'] ?? ''}',
      name: '${map['name'] ?? ''}',
      points: (map['points'] as num?)?.toInt() ?? 0,
      isBot: map['isBot'] == true,
      reconnectingSince: (map['reconnectingSince'] as num?)?.toInt() ?? 0,
      micMuted: map['micMuted'] == true,
      chatBlocked: map['chatBlocked'] == true,
    );
  }
}

class LastPlay {
  const LastPlay({
    required this.name,
    required this.value,
    required this.score,
    required this.nonce,
    required this.outcome,
    required this.redealt,
  });

  final String name;
  final String value;
  final int score;
  final int nonce;
  final String outcome;
  final bool redealt;

  Map<String, dynamic> toMap() => {
    'name': name,
    'value': value,
    'score': score,
    'nonce': nonce,
    'outcome': outcome,
    'redealt': redealt,
  };

  static LastPlay fromMap(Map<dynamic, dynamic> map) {
    return LastPlay(
      name: '${map['name'] ?? ''}',
      value: '${map['value'] ?? ''}',
      score: (map['score'] as num?)?.toInt() ?? 0,
      nonce: (map['nonce'] as num?)?.toInt() ?? 0,
      outcome: '${map['outcome'] ?? ''}',
      redealt: map['redealt'] == true,
    );
  }
}

class SoundCue {
  const SoundCue({
    required this.type,
    required this.nonce,
    this.also = const [],
  });

  final String type;
  final int nonce;
  final List<String> also;

  Map<String, dynamic> toMap() => {'type': type, 'nonce': nonce, 'also': also};

  static SoundCue fromMap(Map<dynamic, dynamic> map) {
    return SoundCue(
      type: '${map['type'] ?? ''}',
      nonce: (map['nonce'] as num?)?.toInt() ?? 0,
      also: [for (final item in (map['also'] as List?) ?? const []) '$item'],
    );
  }
}

/// Card identity first, then at most one point clip. Never laughter,
/// applause, or glass: those belong to [tableSounds] at match end only.
List<String> playCues(Resolution resolution, {required int rank}) {
  final cues = <String>[];
  if (rank == 11 && resolution.skipsNext) {
    cues.add('jack');
  } else if (rank == 3 || rank == 1 || rank == 10) {
    // «صوت كرت ثلاثة» (tableEx) — also for 10 (+10/−10) and Ace (+1/+11).
    cues.add('three');
  } else if (resolution.reversed) {
    cues.add('reverse');
  } else {
    cues.add('ordinary');
  }
  if (resolution.outcome != 'neutral') {
    cues.add(playSound(resolution.outcome));
  }
  return cues;
}

class MatchState {
  const MatchState({
    required this.id,
    required this.name,
    required this.players,
    required this.hostId,
    required this.status,
    required this.pile,
    required this.lastCard,
    required this.turnIndex,
    required this.direction,
    required this.maxPoints,
    required this.timerSeconds,
    required this.teamsEnabled,
    required this.teams,
    required this.deck,
    required this.discard,
    required this.hands,
    required this.lastPlay,
    required this.cue,
    required this.winnerId,
    required this.nonce,
    required this.turnStartedAt,
    this.game = gameEcho99,
    this.board = const {},
  });

  final String id;
  final String name;
  final List<Seat> players;
  final String hostId;
  final String status;
  final int pile;
  final String? lastCard;
  final int turnIndex;
  final int direction;
  final int maxPoints;
  final int timerSeconds;
  final bool teamsEnabled;
  final List<List<String>>? teams;
  final List<String> deck;
  final List<String> discard;
  final Map<String, List<String>> hands;
  final LastPlay? lastPlay;
  final SoundCue? cue;
  final String? winnerId;
  final int nonce;
  final int turnStartedAt;

  /// echo99 | jackaroo | snakes
  final String game;

  /// Game-specific JSON (Jackaroo pieces, Snakes positions, modes...).
  final Map<String, dynamic> board;

  Seat? get current {
    if (turnIndex < 0 || turnIndex >= players.length) {
      return null;
    }
    return players[turnIndex];
  }

  int aliveCount() => players.where((seat) => seat.points > 0).length;

  Map<String, dynamic> toMap() => {
    'id': id,
    'name': name,
    'players': players.map((seat) => seat.toMap()).toList(),
    'hostId': hostId,
    'status': status,
    'pile': pile,
    'lastCard': lastCard,
    'turnIndex': turnIndex,
    'direction': direction,
    'maxPoints': maxPoints,
    'timerSeconds': timerSeconds,
    'teamsEnabled': teamsEnabled,
    'teams': teams,
    'deck': deck,
    'discard': discard,
    'hands': hands,
    'lastPlay': lastPlay?.toMap(),
    'cue': cue?.toMap(),
    'winnerId': winnerId,
    'nonce': nonce,
    'turnStartedAt': turnStartedAt,
    'game': game,
    'board': board,
  };

  static MatchState fromMap(Map<String, dynamic> map, String id) {
    final players = <Seat>[
      for (final raw in (map['players'] as List?) ?? const [])
        if (raw is Map) Seat.fromMap(raw),
    ];
    final hands = <String, List<String>>{};
    final rawHands = map['hands'];
    if (rawHands is Map) {
      rawHands.forEach((key, value) {
        hands['$key'] = [
          for (final card in (value as List?) ?? const []) '$card',
        ];
      });
    }
    List<List<String>>? teams;
    final rawTeams = map['teams'];
    if (rawTeams is List) {
      teams = [
        for (final team in rawTeams)
          if (team is List) [for (final member in team) '$member'],
      ];
    }
    final rawPlay = map['lastPlay'];
    final rawCue = map['cue'];
    final rawLast = map['lastCard'];
    return MatchState(
      id: (map['id'] as String?) ?? id,
      name: '${map['name'] ?? 'طاولة'}',
      players: players,
      hostId: '${map['hostId'] ?? ''}',
      status: '${map['status'] ?? 'waiting'}',
      pile: (map['pile'] as num?)?.toInt() ?? 0,
      lastCard: rawLast == null ? null : '$rawLast',
      turnIndex: (map['turnIndex'] as num?)?.toInt() ?? 0,
      direction: (map['direction'] as num?)?.toInt() ?? 1,
      maxPoints: (map['maxPoints'] as num?)?.toInt() ?? 10,
      timerSeconds: (map['timerSeconds'] as num?)?.toInt() ?? 0,
      teamsEnabled: map['teamsEnabled'] == true,
      teams: teams,
      deck: [for (final card in (map['deck'] as List?) ?? const []) '$card'],
      discard: [
        for (final card in (map['discard'] as List?) ?? const []) '$card',
      ],
      hands: hands,
      lastPlay: rawPlay is Map ? LastPlay.fromMap(rawPlay) : null,
      cue: rawCue is Map ? SoundCue.fromMap(rawCue) : null,
      winnerId: map['winnerId'] == null ? null : '${map['winnerId']}',
      nonce: (map['nonce'] as num?)?.toInt() ?? 0,
      turnStartedAt: (map['turnStartedAt'] as num?)?.toInt() ?? 0,
      game: _gameOf(map['game']),
      board: map['board'] is Map
          ? _jsonMap(map['board'] as Map)
          : const <String, dynamic>{},
    );
  }

  MatchState copyWith({
    String? name,
    List<Seat>? players,
    String? hostId,
    String? status,
    int? pile,
    Object? lastCard = _keep,
    int? turnIndex,
    int? direction,
    int? maxPoints,
    int? timerSeconds,
    bool? teamsEnabled,
    Object? teams = _keep,
    List<String>? deck,
    List<String>? discard,
    Map<String, List<String>>? hands,
    Object? lastPlay = _keep,
    Object? cue = _keep,
    Object? winnerId = _keep,
    int? nonce,
    int? turnStartedAt,
    String? game,
    Map<String, dynamic>? board,
  }) {
    return MatchState(
      id: id,
      name: name ?? this.name,
      players: players ?? this.players,
      hostId: hostId ?? this.hostId,
      status: status ?? this.status,
      pile: pile ?? this.pile,
      lastCard: identical(lastCard, _keep)
          ? this.lastCard
          : lastCard as String?,
      turnIndex: turnIndex ?? this.turnIndex,
      direction: direction ?? this.direction,
      maxPoints: maxPoints ?? this.maxPoints,
      timerSeconds: timerSeconds ?? this.timerSeconds,
      teamsEnabled: teamsEnabled ?? this.teamsEnabled,
      teams: identical(teams, _keep)
          ? this.teams
          : teams as List<List<String>>?,
      deck: deck ?? this.deck,
      discard: discard ?? this.discard,
      hands: hands ?? this.hands,
      lastPlay: identical(lastPlay, _keep)
          ? this.lastPlay
          : lastPlay as LastPlay?,
      cue: identical(cue, _keep) ? this.cue : cue as SoundCue?,
      winnerId: identical(winnerId, _keep)
          ? this.winnerId
          : winnerId as String?,
      nonce: nonce ?? this.nonce,
      turnStartedAt: turnStartedAt ?? this.turnStartedAt,
      game: game ?? this.game,
      board: board ?? this.board,
    );
  }
}

const Object _keep = Object();

const gameEcho99 = 'echo99';
const gameJackaroo = 'jackaroo';
const gameSnakes = 'snakes';
const gameLudo = 'ludo';
const gameThousandMiles = 'thousand_miles';
const supportedGames = [
  gameEcho99,
  gameJackaroo,
  gameSnakes,
  gameLudo,
  gameThousandMiles,
];

String gameLabel(String game) => switch (game) {
  gameJackaroo => 'Jackaroo',
  gameSnakes => 'Snakes and Ladders',
  gameLudo => 'Ludo',
  gameThousandMiles => 'ألف ميل',
  _ => 'Echo99',
};

String _gameOf(Object? raw) {
  final value = '${raw ?? gameEcho99}';
  return supportedGames.contains(value) ? value : gameEcho99;
}

/// Deep-converts Firestore maps to plain JSON maps with String keys.
Map<String, dynamic> _jsonMap(Map<dynamic, dynamic> raw) {
  return {for (final entry in raw.entries) '${entry.key}': _json(entry.value)};
}

dynamic _json(dynamic value) {
  if (value is Map) {
    return _jsonMap(value);
  }
  if (value is List) {
    return [for (final item in value) _json(item)];
  }
  return value;
}

class EngineResult {
  const EngineResult(this.state, [this.error]);

  final MatchState state;
  final String? error;
}

class BotPick {
  const BotPick(this.card, this.choice);

  final String card;
  final int? choice;
}

int? nextLiving(List<Seat> players, int from, int direction, bool skip) {
  if (players.where((seat) => seat.points > 0).length < 2) {
    return null;
  }
  final dir = direction >= 0 ? 1 : -1;
  var steps = skip ? 2 : 1;
  var cursor = from;
  var guard = 0;
  final limit = max(players.length * 4, 4);
  while (steps > 0 && guard < limit) {
    cursor += dir;
    if (cursor >= players.length) {
      cursor = 0;
    }
    if (cursor < 0) {
      cursor = players.length - 1;
    }
    guard += 1;
    if (players[cursor].points > 0) {
      steps -= 1;
    }
  }
  if (steps > 0) {
    return null;
  }
  return cursor;
}

List<String> shuffledDeck(Random random) {
  final deck = [for (final card in PlayingCard.freshDeck()) card.code];
  deck.shuffle(random);
  return deck;
}

void _deal(
  List<Seat> players,
  Map<String, List<String>> hands,
  List<String> deck,
) {
  for (final seat in players) {
    hands[seat.id] = <String>[];
  }
  for (var round = 0; round < 3; round++) {
    for (final seat in players) {
      if (seat.points > 0 && deck.isNotEmpty) {
        hands[seat.id]!.add(deck.removeAt(0));
      }
    }
  }
}

bool _reshuffle(List<String> deck, List<String> discard, Random random) {
  if (discard.length <= 1) {
    return false;
  }
  final top = discard.removeLast();
  deck
    ..clear()
    ..addAll(discard);
  discard
    ..clear()
    ..add(top);
  deck.shuffle(random);
  return true;
}

/// Table settings chosen by the host before the match starts.
class TableSettings {
  const TableSettings({
    required this.startPoints,
    required this.timerSeconds,
    this.teamsEnabled = false,
  });

  /// Starting (and maximum) points per player, 1..99.
  final int startPoints;

  /// 0 means the turn timer is off; otherwise at least [minTimerSeconds].
  final int timerSeconds;
  final bool teamsEnabled;

  bool get timerEnabled => timerSeconds > 0;
}

String? validateSettings(TableSettings settings) {
  if (settings.startPoints < minStartPoints ||
      settings.startPoints > maxStartPoints) {
    return startPointsError;
  }
  if (settings.timerSeconds != 0 && settings.timerSeconds < minTimerSeconds) {
    return timerError;
  }
  return null;
}

/// Reads the host's form. Returns the settings or an Arabic error.
({TableSettings? settings, String? error}) parseTableSettings({
  required String startPointsText,
  required bool timerEnabled,
  required String timerText,
  bool teamsEnabled = false,
}) {
  final points = int.tryParse(startPointsText.trim());
  if (points == null || points < minStartPoints || points > maxStartPoints) {
    return (settings: null, error: startPointsError);
  }
  var timer = 0;
  if (timerEnabled) {
    final seconds = int.tryParse(timerText.trim());
    if (seconds == null || seconds < minTimerSeconds) {
      return (settings: null, error: timerError);
    }
    timer = seconds;
  }
  final settings = TableSettings(
    startPoints: points,
    timerSeconds: timer,
    teamsEnabled: teamsEnabled,
  );
  return (settings: settings, error: validateSettings(settings));
}

/// A waiting table whose players list is exactly one entry: the host.
/// Bots are only ever added through [addBot].
MatchState newWaitingTable({
  required String id,
  required String name,
  required String hostId,
  required String hostName,
  required TableSettings settings,
  String game = gameEcho99,
}) {
  return MatchState(
    game: supportedGames.contains(game) ? game : gameEcho99,
    board: const {},
    id: id,
    name: name.trim().isEmpty ? 'طاولة' : name.trim(),
    players: [
      Seat(
        id: hostId,
        name: hostName,
        points: settings.startPoints,
        isBot: false,
      ),
    ],
    hostId: hostId,
    status: 'waiting',
    pile: 0,
    lastCard: null,
    turnIndex: 0,
    direction: 1,
    maxPoints: settings.startPoints,
    timerSeconds: settings.timerSeconds,
    teamsEnabled: settings.teamsEnabled,
    teams: null,
    deck: const [],
    discard: const [],
    hands: const {},
    lastPlay: null,
    cue: null,
    winnerId: null,
    nonce: 0,
    turnStartedAt: 0,
  );
}

/// Host changes settings before the start. Seats take the new points.
EngineResult applySettings(MatchState state, TableSettings settings) {
  if (state.status != 'waiting') {
    return EngineResult(state, 'لا يمكن تغيير الإعدادات بعد البدء');
  }
  final error = validateSettings(settings);
  if (error != null) {
    return EngineResult(state, error);
  }
  return EngineResult(
    MatchState(
      id: state.id,
      game: state.game,
      board: state.board,
      name: state.name,
      players: [
        for (final seat in state.players)
          seat.copyWith(points: settings.startPoints),
      ],
      hostId: state.hostId,
      status: state.status,
      pile: state.pile,
      lastCard: state.lastCard,
      turnIndex: state.turnIndex,
      direction: state.direction,
      maxPoints: settings.startPoints,
      timerSeconds: settings.timerSeconds,
      teamsEnabled: settings.teamsEnabled,
      teams: state.teams,
      deck: state.deck,
      discard: state.discard,
      hands: state.hands,
      lastPlay: state.lastPlay,
      cue: state.cue,
      winnerId: state.winnerId,
      nonce: state.nonce + 1,
      turnStartedAt: state.turnStartedAt,
    ),
  );
}

String? validateStart(MatchState state) {
  final count = state.players.length;
  if (count < 2 || count > 10) {
    return playerCountError;
  }
  if (state.maxPoints < minStartPoints || state.maxPoints > maxStartPoints) {
    return startPointsError;
  }
  if (state.timerSeconds != 0 && state.timerSeconds < minTimerSeconds) {
    return timerError;
  }
  if (state.teamsEnabled && !const {4, 6, 8, 10}.contains(count)) {
    return teamsCountError;
  }
  return null;
}

List<List<String>>? _teamsFor(MatchState state, List<Seat> players) {
  if (!state.teamsEnabled) {
    return null;
  }
  final first = <String>[];
  final second = <String>[];
  for (var index = 0; index < players.length; index++) {
    (index.isEven ? first : second).add(players[index].id);
  }
  return [first, second];
}

EngineResult startMatch(MatchState state, Random random, int nowMillis) {
  final error = validateStart(state);
  if (error != null) {
    return EngineResult(state, error);
  }
  if (state.status != 'waiting') {
    return EngineResult(state, 'المباراة بدأت');
  }
  final players = [
    for (final seat in state.players) seat.copyWith(points: state.maxPoints),
  ];
  final deck = shuffledDeck(random);
  final hands = <String, List<String>>{};
  _deal(players, hands, deck);
  final nonce = state.nonce + 1;
  // Host ALWAYS first turn after deal.
  var hostTurn = players.indexWhere((seat) => seat.id == state.hostId);
  if (hostTurn < 0) {
    hostTurn = 0;
  }
  return EngineResult(
    MatchState(
      id: state.id,
      game: state.game,
      board: state.board,
      name: state.name,
      players: players,
      hostId: state.hostId,
      status: 'playing',
      pile: 0,
      lastCard: null,
      turnIndex: hostTurn,
      direction: 1,
      maxPoints: state.maxPoints,
      timerSeconds: state.timerSeconds,
      teamsEnabled: state.teamsEnabled,
      teams: _teamsFor(state, players),
      deck: deck,
      discard: const [],
      hands: hands,
      lastPlay: null,
      cue: SoundCue(type: 'shuffle', nonce: nonce),
      winnerId: null,
      nonce: nonce,
      turnStartedAt: nowMillis,
    ),
  );
}

EngineResult addBot(MatchState state, String botId, String botName) {
  if (state.status != 'waiting') {
    return EngineResult(state, 'لا يمكن إضافة بوت بعد البدء');
  }
  if (state.players.length >= 10) {
    return EngineResult(state, 'الحد عشرة لاعبين.');
  }
  return EngineResult(
    MatchState(
      id: state.id,
      game: state.game,
      board: state.board,
      name: state.name,
      players: [
        ...state.players,
        Seat(id: botId, name: botName, points: state.maxPoints, isBot: true),
      ],
      hostId: state.hostId,
      status: state.status,
      pile: state.pile,
      lastCard: state.lastCard,
      turnIndex: state.turnIndex,
      direction: state.direction,
      maxPoints: state.maxPoints,
      timerSeconds: state.timerSeconds,
      teamsEnabled: state.teamsEnabled,
      teams: state.teams,
      deck: state.deck,
      discard: state.discard,
      hands: state.hands,
      lastPlay: state.lastPlay,
      cue: state.cue,
      winnerId: state.winnerId,
      nonce: state.nonce,
      turnStartedAt: state.turnStartedAt,
    ),
  );
}

EngineResult kickPlayer(MatchState state, String targetId, int nowMillis) {
  return clearHandsIfFinished(_kickRaw(state, targetId, nowMillis));
}

EngineResult _kickRaw(MatchState state, String targetId, int nowMillis) {
  final index = state.players.indexWhere((seat) => seat.id == targetId);
  if (index < 0) {
    return EngineResult(state, 'اللاعب غير موجود');
  }
  final players = [...state.players]..removeAt(index);
  final hands = {
    for (final entry in state.hands.entries)
      if (entry.key != targetId) entry.key: [...entry.value],
  };
  final deck = [...state.deck, ...(state.hands[targetId] ?? const <String>[])];
  var turn = state.turnIndex;
  if (players.isEmpty) {
    turn = 0;
  } else if (index < turn) {
    turn -= 1;
  } else if (index == turn) {
    turn = turn % players.length;
  }
  if (turn >= players.length) {
    turn = players.isEmpty ? 0 : 0;
  }
  if (players.isNotEmpty && players[turn].points <= 0) {
    final next = nextLiving(
      players,
      (turn - 1 + players.length) % players.length,
      state.direction,
      false,
    );
    if (next != null) {
      turn = next;
    }
  }
  var status = state.status;
  String? winner = state.winnerId;
  if (status == 'playing') {
    final alive = players.where((seat) => seat.points > 0).toList();
    if (alive.length < 2) {
      status = 'finished';
      winner = alive.isEmpty ? null : alive.first.id;
    }
  }
  return EngineResult(
    MatchState(
      id: state.id,
      game: state.game,
      board: state.board,
      name: state.name,
      players: players,
      hostId: state.hostId,
      status: status,
      pile: state.pile,
      lastCard: state.lastCard,
      turnIndex: turn,
      direction: state.direction,
      maxPoints: state.maxPoints,
      timerSeconds: state.timerSeconds,
      teamsEnabled: state.teamsEnabled,
      teams: state.teams
          ?.map((team) => team.where((id) => id != targetId).toList())
          .where((team) => team.isNotEmpty)
          .toList(),
      deck: deck,
      discard: state.discard,
      hands: hands,
      lastPlay: state.lastPlay,
      cue: state.cue,
      winnerId: winner,
      nonce: state.nonce + 1,
      turnStartedAt: nowMillis,
    ),
  );
}

List<Seat> _deduct(List<Seat> players, int index, int amount) {
  if (amount <= 0 || index < 0 || index >= players.length) {
    return players;
  }
  final seat = players[index];
  if (seat.points <= 0) {
    return players;
  }
  final next = [...players];
  next[index] = seat.copyWith(points: max(0, seat.points - amount));
  return next;
}

bool playerWonMatch(MatchState state, String playerId) {
  if (state.status != 'finished' || playerId.isEmpty) {
    return false;
  }
  final winner = state.winnerId;
  if (winner == null || winner.isEmpty) {
    return false;
  }
  if (winner == playerId) {
    return true;
  }
  final teams = state.teams;
  if (teams == null) {
    return false;
  }
  for (final team in teams) {
    if (team.contains(winner) && team.contains(playerId)) {
      return true;
    }
  }
  return false;
}

String? _winnerId(List<Seat> players) {
  final alive = players.where((seat) => seat.points > 0).toList();
  if (alive.length == 1) {
    return alive.first.id;
  }
  return null;
}

/// Echo99 card play. When the match ends every hand is cleared so no stale
/// cards stay on screen; the host then offers «إعادة اللعب».
EngineResult playCard(
  MatchState state, {
  required String playerId,
  required String cardCode,
  int? choice,
  required Random random,
  required int nowMillis,
}) {
  return clearHandsIfFinished(
    _playCardRaw(
      state,
      playerId: playerId,
      cardCode: cardCode,
      choice: choice,
      random: random,
      nowMillis: nowMillis,
    ),
  );
}

EngineResult clearHandsIfFinished(EngineResult result) {
  if (result.error != null || result.state.status != 'finished') {
    return result;
  }
  return EngineResult(
    result.state.copyWith(hands: const {}, deck: const [], discard: const []),
  );
}

EngineResult _playCardRaw(
  MatchState state, {
  required String playerId,
  required String cardCode,
  int? choice,
  required Random random,
  required int nowMillis,
}) {
  if (state.status != 'playing') {
    return EngineResult(state, 'المباراة ليست جارية');
  }
  final actor = state.turnIndex;
  final seat = state.current;
  if (seat == null || seat.id != playerId || seat.points <= 0) {
    return EngineResult(state, 'ليس دورك');
  }
  final hand = [...(state.hands[seat.id] ?? const <String>[])];
  final cardIndex = hand.indexOf(cardCode);
  if (cardIndex < 0) {
    return EngineResult(state, 'الورقة غير موجودة');
  }
  final card = PlayingCard.parse(cardCode);
  if (card == null) {
    return EngineResult(state, 'الورقة غير موجودة');
  }
  if (card.rank == 1 && choice != 1 && choice != 11) {
    return EngineResult(state, 'اختر 1 أو 11 للآس');
  }
  if (card.rank == 10 && choice != 10 && choice != -10) {
    return EngineResult(state, 'اختر 10 أو -10');
  }
  final before = state.pile;
  final active = state.aliveCount();
  final after = appliedTotal(before, card.rank, choice: choice);
  final resolution = resolvePlay(
    before: before,
    after: after,
    rank: card.rank,
    activePlayers: active,
  );
  hand.removeAt(cardIndex);
  final hands = {
    for (final entry in state.hands.entries) entry.key: [...entry.value],
  };
  hands[seat.id] = hand;
  final discard = [...state.discard, cardCode];
  final deck = [...state.deck];
  var players = [...state.players];
  players = _deduct(players, actor, resolution.actorLoss);
  if (resolution.othersLoss > 0) {
    for (var index = 0; index < players.length; index++) {
      if (index != actor) {
        players = _deduct(players, index, resolution.othersLoss);
      }
    }
  }
  final value = spokenValue(
    rank: card.rank,
    before: before,
    after: after,
    choice: choice,
  );
  final nonce = state.nonce + 1;
  final speech = LastPlay(
    name: seat.name,
    value: value,
    score: after,
    nonce: nonce,
    outcome: resolution.outcome,
    redealt: false,
  );
  if (resolution.roundEnded) {
    final alive = players.where((item) => item.points > 0).length;
    if (alive < 2) {
      return EngineResult(
        MatchState(
          id: state.id,
          game: state.game,
          board: state.board,
          name: state.name,
          players: players,
          hostId: state.hostId,
          status: 'finished',
          pile: 0,
          lastCard: cardCode,
          turnIndex: actor < players.length ? actor : 0,
          direction: state.direction,
          maxPoints: state.maxPoints,
          timerSeconds: state.timerSeconds,
          teamsEnabled: state.teamsEnabled,
          teams: state.teams,
          deck: deck,
          discard: discard,
          hands: hands,
          lastPlay: speech,
          cue: SoundCue(
            type: 'metal',
            nonce: nonce,
            also: playCues(resolution, rank: card.rank),
          ),
          winnerId: _winnerId(players),
          nonce: nonce,
          turnStartedAt: nowMillis,
        ),
      );
    }
    final fresh = shuffledDeck(random);
    final redealt = <String, List<String>>{};
    _deal(players, redealt, fresh);
    // Host always takes the first turn after every deal / redeal.
    var starter = players.indexWhere((item) => item.id == state.hostId);
    if (starter < 0 || players[starter].points <= 0) {
      starter = players.indexWhere((item) => item.points > 0);
    }
    return EngineResult(
      MatchState(
        id: state.id,
        game: state.game,
        board: state.board,
        name: state.name,
        players: players,
        hostId: state.hostId,
        status: 'playing',
        pile: 0,
        lastCard: cardCode,
        turnIndex: starter < 0 ? 0 : starter,
        direction: 1,
        maxPoints: state.maxPoints,
        timerSeconds: state.timerSeconds,
        teamsEnabled: state.teamsEnabled,
        teams: state.teams,
        deck: fresh,
        discard: const [],
        hands: redealt,
        lastPlay: LastPlay(
          name: speech.name,
          value: speech.value,
          score: speech.score,
          nonce: nonce,
          outcome: speech.outcome,
          redealt: true,
        ),
        cue: SoundCue(
          type: resolution.outcome == 'bust' ? 'glass' : 'metal',
          nonce: nonce,
          also: playCues(resolution, rank: card.rank),
        ),
        winnerId: null,
        nonce: nonce,
        turnStartedAt: nowMillis,
      ),
    );
  }

  var direction = state.direction >= 0 ? 1 : -1;
  if (resolution.reversed) {
    direction = -direction;
  }
  var cueType = 'play';
  if (resolution.outcome == 'bust') {
    cueType = 'glass';
  }
  if (players[actor].points > 0) {
    if (deck.isEmpty) {
      _reshuffle(deck, discard, random);
    }
    if (deck.isNotEmpty) {
      hands[seat.id] = [...hand, deck.removeAt(0)];
    }
  }
  if (players.where((item) => item.points > 0).length < 2) {
    return EngineResult(
      MatchState(
        id: state.id,
        game: state.game,
        board: state.board,
        name: state.name,
        players: players,
        hostId: state.hostId,
        status: 'finished',
        pile: resolution.nextTotal,
        lastCard: cardCode,
        turnIndex: actor,
        direction: direction,
        maxPoints: state.maxPoints,
        timerSeconds: state.timerSeconds,
        teamsEnabled: state.teamsEnabled,
        teams: state.teams,
        deck: deck,
        discard: discard,
        hands: hands,
        lastPlay: speech,
        cue: SoundCue(
          type: cueType,
          nonce: nonce,
          also: playCues(resolution, rank: card.rank),
        ),
        winnerId: _winnerId(players),
        nonce: nonce,
        turnStartedAt: nowMillis,
      ),
    );
  }
  final next = nextLiving(players, actor, direction, resolution.skipsNext);
  return EngineResult(
    MatchState(
      id: state.id,
      game: state.game,
      board: state.board,
      name: state.name,
      players: players,
      hostId: state.hostId,
      status: 'playing',
      pile: resolution.nextTotal,
      lastCard: cardCode,
      turnIndex: next ?? actor,
      direction: direction,
      maxPoints: state.maxPoints,
      timerSeconds: state.timerSeconds,
      teamsEnabled: state.teamsEnabled,
      teams: state.teams,
      deck: deck,
      discard: discard,
      hands: hands,
      lastPlay: speech,
      cue: SoundCue(
        type: cueType,
        nonce: nonce,
        also: playCues(resolution, rank: card.rank),
      ),
      winnerId: null,
      nonce: nonce,
      turnStartedAt: nowMillis,
    ),
  );
}

BotPick? chooseBot(MatchState state) {
  final seat = state.current;
  if (seat == null) {
    return null;
  }
  final hand = state.hands[seat.id] ?? const <String>[];
  if (hand.isEmpty) {
    return null;
  }
  final active = state.aliveCount();
  BotPick? best;
  var bestScore = -1 << 30;
  for (final code in hand) {
    final card = PlayingCard.parse(code);
    if (card == null) {
      continue;
    }
    for (final option in choicesForRank(card.rank)) {
      final after = appliedTotal(state.pile, card.rank, choice: option);
      final resolution = resolvePlay(
        before: state.pile,
        after: after,
        rank: card.rank,
        activePlayers: active,
      );
      final score = botRankScore(
        before: state.pile,
        after: after,
        resolution: resolution,
        rank: card.rank,
        activePlayers: active,
      );
      if (best == null || score > bestScore) {
        best = BotPick(code, option);
        bestScore = score;
      }
    }
  }
  return best;
}

int remainingSeconds(MatchState state, int nowMillis) {
  if (state.timerSeconds < 10 || state.status != 'playing') {
    return 0;
  }
  if (state.turnStartedAt <= 0) {
    return state.timerSeconds;
  }
  final elapsed = ((nowMillis - state.turnStartedAt) / 1000).floor();
  final left = state.timerSeconds - elapsed;
  return left < 0 ? 0 : left;
}
