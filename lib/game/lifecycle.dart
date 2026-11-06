import 'dart:math';

import 'engine.dart';
import 'jackaroo.dart';
import 'snakes.dart';
import 'ludo.dart';
import 'thousand_miles.dart';

/// Seconds a dropped human keeps their seat and score before being
/// replaced by a bot (match running) or removed (waiting table).
const reconnectGraceSeconds = 60;
const reconnectingLabel = 'Reconnecting...';

enum GraceStatus { connected, reconnecting, expired }

/// Pure 60 s reconnect grace rule.
GraceStatus graceStatus({
  required int disconnectedAtMillis,
  required int nowMillis,
  int graceSeconds = reconnectGraceSeconds,
}) {
  if (disconnectedAtMillis <= 0) {
    return GraceStatus.connected;
  }
  final elapsed = nowMillis - disconnectedAtMillis;
  return elapsed >= graceSeconds * 1000
      ? GraceStatus.expired
      : GraceStatus.reconnecting;
}

int graceSecondsLeft({
  required int disconnectedAtMillis,
  required int nowMillis,
  int graceSeconds = reconnectGraceSeconds,
}) {
  if (disconnectedAtMillis <= 0) {
    return graceSeconds;
  }
  final left =
      graceSeconds - ((nowMillis - disconnectedAtMillis) / 1000).floor();
  return left < 0 ? 0 : left;
}

/// Marks a human seat as dropped (keeps seat and score).
EngineResult markReconnectingSeat(MatchState state, String playerId, int now) {
  final index = state.players.indexWhere((s) => s.id == playerId);
  if (index < 0) {
    return EngineResult(state, 'اللاعب غير موجود');
  }
  final seat = state.players[index];
  if (seat.isBot || seat.reconnecting) {
    return EngineResult(state);
  }
  final players = [...state.players];
  players[index] = seat.copyWith(reconnectingSince: now);
  return EngineResult(state.copyWith(players: players, nonce: state.nonce + 1));
}

/// The player came back inside the grace window.
EngineResult markReconnectedSeat(MatchState state, String playerId) {
  final index = state.players.indexWhere((s) => s.id == playerId);
  if (index < 0) {
    return EngineResult(state, 'اللاعب غير موجود');
  }
  final seat = state.players[index];
  if (!seat.reconnecting) {
    return EngineResult(state);
  }
  final players = [...state.players];
  players[index] = seat.copyWith(reconnectingSince: 0);
  return EngineResult(state.copyWith(players: players, nonce: state.nonce + 1));
}

/// Swaps a human seat for a bot that keeps the seat's score, cards and
/// pieces, so the match continues. Waiting tables just drop the seat.
EngineResult replaceWithBot(
  MatchState state,
  String playerId, {
  required String botId,
  required String botName,
  required int nowMillis,
}) {
  final index = state.players.indexWhere((s) => s.id == playerId);
  if (index < 0) {
    return EngineResult(state, 'اللاعب غير موجود');
  }
  if (state.status != 'playing') {
    return kickPlayer(state, playerId, nowMillis);
  }
  final players = [...state.players];
  players[index] = players[index].copyWith(
    id: botId,
    name: botName,
    isBot: true,
    reconnectingSince: 0,
  );
  String swap(String id) => id == playerId ? botId : id;
  final hands = {
    for (final e in state.hands.entries) swap(e.key): [...e.value],
  };
  final board = _remapBoard(state.board, playerId, botId);
  return EngineResult(
    state.copyWith(
      players: players,
      hands: hands,
      teams: state.teams
          ?.map((team) => [for (final id in team) swap(id)])
          .toList(),
      board: board,
      nonce: state.nonce + 1,
      turnStartedAt: state.current?.id == playerId
          ? nowMillis
          : state.turnStartedAt,
    ),
  );
}

Map<String, dynamic> _remapBoard(
  Map<String, dynamic> board,
  String from,
  String to,
) {
  final out = <String, dynamic>{};
  for (final entry in board.entries) {
    final value = entry.value;
    if (value is Map &&
        const {'pieces', 'colors', 'positions', 'tableaux', 'hasKilled'}.contains(entry.key)) {
      out[entry.key] = {
        for (final e in value.entries)
          ('${e.key}' == from ? to : '${e.key}'): e.value,
      };
    } else {
      out[entry.key] = value;
    }
  }
  return out;
}

/// Applies the grace rule to every dropped seat. Returns null when nothing
/// expired. Expired seats become bots (playing) or leave (waiting).
EngineResult? expireGraceSeats(
  MatchState state, {
  required int nowMillis,
  required String Function(Seat seat) botIdFor,
}) {
  var current = state;
  var changed = false;
  for (final seat in state.players) {
    if (seat.isBot || !seat.reconnecting) {
      continue;
    }
    final status = graceStatus(
      disconnectedAtMillis: seat.reconnectingSince,
      nowMillis: nowMillis,
    );
    if (status != GraceStatus.expired) {
      continue;
    }
    if (seat.id == current.hostId) {
      continue; // the host's table is cleaned up by the presence layer
    }
    final result = replaceWithBot(
      current,
      seat.id,
      botId: botIdFor(seat),
      botName: 'بوت (${seat.name})',
      nowMillis: nowMillis,
    );
    if (result.error == null) {
      current = result.state;
      changed = true;
    }
  }
  return changed ? EngineResult(current) : null;
}

/// «إعادة اللعب»: back to waiting with the same players and settings.
EngineResult resetForReplay(MatchState state) {
  if (state.status != 'finished') {
    return EngineResult(state, 'المباراة لم تنته');
  }
  final mode = state.board['mode'];
  return EngineResult(
    state.copyWith(
      players: [
        for (final s in state.players)
          s.copyWith(points: state.maxPoints, reconnectingSince: 0),
      ],
      status: 'waiting',
      pile: 0,
      lastCard: null,
      turnIndex: 0,
      direction: 1,
      deck: const [],
      discard: const [],
      hands: const {},
      lastPlay: null,
      cue: null,
      winnerId: null,
      nonce: state.nonce + 1,
      board: {'mode': ?mode},
    ),
  );
}

/// Starts whichever game the host picked when creating the table.
EngineResult startGame(MatchState state, Random random, int nowMillis) {
  if (state.status != 'waiting') {
    return EngineResult(state, 'المباراة بدأت');
  }
  switch (state.game) {
    case gameJackaroo:
      return startJackaroo(state, random, nowMillis);
    case gameSnakes:
      return startSnakes(state, nowMillis);
    case gameLudo:
      return startLudo(state, random, nowMillis);
    case gameThousandMiles:
      return startMiles(state, random, nowMillis);
    default:
      return startMatch(state, random, nowMillis);
  }
}

/// Host picks the Jackaroo mode in the بدء dialog.
EngineResult applyJackarooMode(
  MatchState state,
  String mode,
  int timer, {
  bool? teams,
}) {
  if (state.status != 'waiting') {
    return EngineResult(state, 'لا يمكن تغيير الإعدادات بعد البدء');
  }
  return EngineResult(
    state.copyWith(
      timerSeconds: timer,
      board: {
        ...state.board,
        'mode': mode == jackarooComplex ? jackarooComplex : jackarooStandard,
        // Host's 4-player choice: teams (شركاء) vs individual. Omitted keeps
        // the previous setting.
        'teams': ?teams,
      },
      nonce: state.nonce + 1,
    ),
  );
}

/// Seat cap per game.
int maxSeatsFor(String game) => switch (game) {
  gameJackaroo => 4,
  gameSnakes => 6,
  gameLudo => 4,
  gameThousandMiles => 9,
  _ => 10,
};
