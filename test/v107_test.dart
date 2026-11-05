import 'dart:math';

import 'package:echo99/game/engine.dart';
import 'package:echo99/game/jackaroo.dart';
import 'package:echo99/game/lifecycle.dart';
import 'package:echo99/game/snakes.dart';
import 'package:echo99/screens/create_table_screen.dart';
import 'package:echo99/screens/table_screen.dart';
import 'package:echo99/services/presence.dart';
import 'package:flutter_test/flutter_test.dart';

MatchState _echoAt(int pile, List<String> hand) {
  var state = newWaitingTable(
    id: 't',
    name: 'طاولة',
    hostId: 'h',
    hostName: 'علي',
    settings: const TableSettings(startPoints: 10, timerSeconds: 0),
  );
  state = addBot(state, 'b1', 'بوت 1').state;
  state = startMatch(state, Random(1), 0).state;
  return MatchState.fromMap({
    ...state.toMap(),
    'pile': pile,
    'turnIndex': 0,
    'hands': {...state.hands, 'h': hand},
  }, 't');
}

MatchState _jackaroo({
  required List<int> a,
  required List<int> b,
  List<String> handA = const ['S1'],
  String mode = jackarooStandard,
}) {
  var state = newWaitingTable(
    id: 'j',
    name: 'طاولة',
    hostId: 'A',
    hostName: 'A',
    settings: const TableSettings(startPoints: 10, timerSeconds: 0),
    game: gameJackaroo,
  );
  state = addBot(state, 'B', 'B').state;
  state = applyJackarooMode(state, mode, 0).state;
  state = startGame(state, Random(2), 0).state;
  return MatchState.fromMap({
    ...state.toMap(),
    'turnIndex': 0,
    'hands': {
      'A': handA,
      'B': ['H2', 'H3'],
    },
    'board': {
      'mode': mode,
      'colors': {'A': 0, 'B': 1},
      'pieces': {'A': a, 'B': b},
    },
  }, 'j');
}

const h = jackarooHome;

void main() {
  group('Echo99 33/66 never resets the sum', () {
    test('exact 33 keeps the pile at 33, then 33+10 = 43', () {
      final at23 = _echoAt(23, ['S10', 'C5', 'D6', 'H7']);
      final hit33 = playCard(
        at23,
        playerId: 'h',
        cardCode: 'S10',
        choice: 10,
        random: Random(1),
        nowMillis: 0,
      ).state;
      expect(hit33.pile, 33);
      expect(hit33.lastPlay!.outcome, 'exact33');
      expect(hit33.lastPlay!.redealt, isFalse);
      expect(hit33.status, 'playing');

      final at33 = MatchState.fromMap({
        ...hit33.toMap(),
        'turnIndex': 0,
        'hands': {
          ...hit33.hands,
          'h': ['C13'],
        },
      }, 't');
      final before = at33.players.first.points;
      final cross = playCard(
        at33,
        playerId: 'h',
        cardCode: 'C13',
        random: Random(1),
        nowMillis: 0,
      ).state;
      expect(cross.pile, 43, reason: '33 + 10 continues, no reset');
      expect(cross.players.first.points, before);
      expect(cross.lastPlay!.outcome, 'neutral');
    });

    test('exact 66 keeps accumulating; only 99 / bust reset', () {
      final at56 = _echoAt(56, ['H10']);
      final hit66 = playCard(
        at56,
        playerId: 'h',
        cardCode: 'H10',
        choice: 10,
        random: Random(1),
        nowMillis: 0,
      ).state;
      expect(hit66.pile, 66);
      final at89 = _echoAt(89, ['H10']);
      final hit99 = playCard(
        at89,
        playerId: 'h',
        cardCode: 'H10',
        choice: 10,
        random: Random(1),
        nowMillis: 0,
      ).state;
      expect(hit99.pile, 0);
      expect(hit99.lastPlay!.outcome, 'exact99');
      final at95 = _echoAt(95, ['H10']);
      final bust = playCard(
        at95,
        playerId: 'h',
        cardCode: 'H10',
        choice: 10,
        random: Random(1),
        nowMillis: 0,
      ).state;
      expect(bust.pile, 0);
      expect(bust.lastPlay!.outcome, 'bust');
    });
  });

  group('table create flow', () {
    test('instant create: host only, host name, chosen game, no settings', () {
      for (final game in supportedGames) {
        final table = newWaitingTable(
          id: 'x',
          name: defaultTableName('علي'),
          hostId: 'host',
          hostName: 'علي',
          settings: defaultCreateSettings,
          game: game,
        );
        expect(table.name, 'طاولة علي');
        expect(table.game, game);
        expect(table.status, 'waiting');
        expect(table.players.map((s) => s.name), ['علي']);
        final synced = MatchState.fromMap(table.toMap(), 'x');
        expect(synced.game, game);
      }
    });

    test('settings arrive only at بدء and are announced', () {
      var table = newWaitingTable(
        id: 'x',
        name: 'طاولة علي',
        hostId: 'host',
        hostName: 'علي',
        settings: defaultCreateSettings,
      );
      table = addBot(table, 'b', 'بوت').state;
      table = applySettings(
        table,
        const TableSettings(startPoints: 20, timerSeconds: 15),
      ).state;
      final started = startGame(table, Random(1), 0).state;
      expect(started.status, 'playing');
      expect(started.current!.id, 'host');
      expect(
        settingsAnnouncement(started),
        'إعدادات الطاولة — أقصى نقاط: 20، مؤقت الدور: 15',
      );
    });

    test('game end clears cards and «إعادة اللعب» restarts', () {
      final at95 = _echoAt(95, ['H10']);
      // Leave the actor with 2 points so a bust eliminates them.
      final fragile = at95.copyWith(
        players: [at95.players[0].copyWith(points: 2), at95.players[1]],
      );
      final end = playCard(
        fragile,
        playerId: 'h',
        cardCode: 'H10',
        choice: 10,
        random: Random(1),
        nowMillis: 0,
      ).state;
      expect(end.status, 'finished');
      expect(end.hands, isEmpty);
      final reset = resetForReplay(end).state;
      expect(reset.status, 'waiting');
      expect(reset.players.every((s) => s.points == reset.maxPoints), isTrue);
      final again = startGame(reset, Random(3), 0).state;
      expect(again.status, 'playing');
      expect(again.hands['h'], hasLength(4));
    });
  });

  group('Jackaroo basics', () {
    test('Ace exits a yard piece onto its base square', () {
      final s = _jackaroo(a: [h, h, h, h], b: [h, h, h, h]);
      final moves = jackarooMovesForCard(s, 'A', 'S1');
      expect(moves.map((m) => m.kind), contains('exit'));
      final next = playJackaroo(
        s,
        playerId: 'A',
        move: moves.firstWhere((m) => m.kind == 'exit'),
        random: Random(1),
        nowMillis: 0,
      ).state;
      final board = JackarooBoard.of(next);
      expect(board.pieces['A']![0], 0);
      expect(board.absolute('A', 0), 0);
      expect(next.current!.id, 'B');
    });

    test('blue base is 19; yellow 57; landing kills', () {
      expect(jackarooBases, [0, 19, 38, 57]);
      // A at 10 moves 5 → 15 where B sits (B progress 72 = abs (19+72)%76 = 15).
      final s = _jackaroo(a: [10, h, h, h], b: [72, h, h, h], handA: ['S5']);
      final move = jackarooMovesForCard(s, 'A', 'S5').single;
      final next = playJackaroo(
        s,
        playerId: 'A',
        move: move,
        random: Random(1),
        nowMillis: 0,
      ).state;
      final board = JackarooBoard.of(next);
      expect(board.pieces['A']![0], 15);
      expect(board.pieces['B']![0], h, reason: 'killed back to the yard');
    });

    test('same color cannot pass its own piece', () {
      final s = _jackaroo(a: [10, 12, h, h], b: [h, h, h, h], handA: ['S5']);
      final moves = jackarooMovesForCard(s, 'A', 'S5');
      expect(moves.any((m) => m.piece == 0), isFalse);
      expect(moves.any((m) => m.piece == 1), isTrue);
    });

    test('a piece on its own base is safe and blocks passing', () {
      // B on its base (abs 19). A at 16 cannot move 5 past it.
      final s = _jackaroo(a: [16, h, h, h], b: [0, h, h, h], handA: ['S5']);
      expect(jackarooMovesForCard(s, 'A', 'S5'), isEmpty);
    });

    test('two adjacent same-color pieces form a wall', () {
      // B at abs 30, 31 (progress 11, 12). A at 28 can't pass with a 5.
      final s = _jackaroo(a: [28, h, h, h], b: [11, 12, h, h], handA: ['S5']);
      expect(jackarooMovesForCard(s, 'A', 'S5'), isEmpty);
      // A single piece can be jumped.
      final single = _jackaroo(
        a: [28, h, h, h],
        b: [11, h, h, h],
        handA: ['S5'],
      );
      expect(jackarooMovesForCard(single, 'A', 'S5'), hasLength(1));
    });

    test('4 moves backward; Jack swaps; safe zone needs exact count', () {
      final back = _jackaroo(a: [10, h, h, h], b: [h, h, h, h], handA: ['S4']);
      final b4 = jackarooMovesForCard(back, 'A', 'S4').single;
      expect(b4.kind, 'back');
      final moved = playJackaroo(
        back,
        playerId: 'A',
        move: b4,
        random: Random(1),
        nowMillis: 0,
      ).state;
      expect(JackarooBoard.of(moved).pieces['A']![0], 6);

      final swap = _jackaroo(a: [10, h, h, h], b: [5, h, h, h], handA: ['S11']);
      final jack = jackarooMovesForCard(swap, 'A', 'S11').single;
      final swapped = playJackaroo(
        swap,
        playerId: 'A',
        move: jack,
        random: Random(1),
        nowMillis: 0,
      ).state;
      final board = JackarooBoard.of(swapped);
      expect(board.absolute('A', board.pieces['A']![0]), 24);
      expect(board.absolute('B', board.pieces['B']![0]), 10);

      final near = _jackaroo(a: [74, h, h, h], b: [h, h, h, h], handA: ['S8']);
      expect(jackarooMovesForCard(near, 'A', 'S8'), isEmpty);
      final fits = _jackaroo(a: [74, h, h, h], b: [h, h, h, h], handA: ['S5']);
      expect(jackarooMovesForCard(fits, 'A', 'S5'), hasLength(1));
    });

    test('Semantics text lists every piece', () {
      final s = _jackaroo(a: [10, h, 77, h], b: [h, h, h, h]);
      final text = jackarooPositionsText(s);
      // 1-based squares (index 10 = «الخانة 11»), base = «في القاعدة».
      expect(text, contains('الخانة 11'));
      expect(text, contains('المنطقة الآمنة 2'));
      expect(text, contains('في القاعدة'));
    });

    test('bot always finds a legal move or burns', () {
      final s = _jackaroo(a: [h, h, h, h], b: [h, h, h, h], handA: ['S9']);
      final move = chooseJackarooBot(s)!;
      expect(move.kind, 'burnAll');
    });
  });

  group('Snakes and Ladders', () {
    test('exact 100 wins, overshoot stays', () {
      expect(snakesMove(97, 5).to, 97);
      expect(snakesMove(97, 5).jump, 'over');
      expect(snakesMove(97, 3).won, isTrue);
      expect(snakesMove(3, 1).to, 14, reason: 'ladder 4 → 14');
      expect(snakesMove(11, 6).to, 7, reason: 'snake 17 → 7');
    });

    test('roll plays the ding N times then ladder / snake', () {
      expect(snakesSounds(snakesMove(40, 4)), [
        snakesRollSound,
        ...List.filled(4, snakesDingSound),
      ]);
      expect(snakesSounds(snakesMove(3, 1)), [
        snakesRollSound,
        snakesDingSound,
        snakesLadderSound,
      ]);
      expect(snakesSounds(snakesMove(11, 6)).last, snakesSnakeSound);
    });

    test('engine: start at 0, turn passes, 100 finishes', () {
      var s = newWaitingTable(
        id: 's',
        name: 'طاولة',
        hostId: 'A',
        hostName: 'A',
        settings: defaultCreateSettings,
        game: gameSnakes,
      );
      s = addBot(s, 'B', 'B').state;
      s = startGame(s, Random(1), 0).state;
      expect(snakesPositions(s), {'A': 0, 'B': 0});
      s = rollSnakes(s, playerId: 'A', roll: 3, nowMillis: 0).state;
      expect(snakesPositions(s)['A'], 3);
      expect(s.current!.id, 'B');
      expect(
        rollSnakes(s, playerId: 'A', roll: 3, nowMillis: 0).error,
        isNotNull,
      );
      final near = MatchState.fromMap({
        ...s.toMap(),
        'turnIndex': 0,
        'board': {
          'positions': {'A': 96, 'B': 0},
        },
      }, 's');
      final won = rollSnakes(near, playerId: 'A', roll: 4, nowMillis: 0).state;
      expect(won.status, 'finished');
      expect(won.winnerId, 'A');
      expect(snakesOwnText(won, 'A'), 'أنت في المربع 100');
    });
  });

  group('60 s reconnect grace', () {
    test('status transitions', () {
      expect(
        graceStatus(disconnectedAtMillis: 0, nowMillis: 5),
        GraceStatus.connected,
      );
      expect(
        graceStatus(disconnectedAtMillis: 1000, nowMillis: 60999),
        GraceStatus.reconnecting,
      );
      expect(
        graceStatus(disconnectedAtMillis: 1000, nowMillis: 61000),
        GraceStatus.expired,
      );
      expect(graceSecondsLeft(disconnectedAtMillis: 0, nowMillis: 30000), 60);
      expect(
        graceSecondsLeft(disconnectedAtMillis: 1000, nowMillis: 31000),
        30,
      );
    });

    MatchState playing() {
      var s = newWaitingTable(
        id: 'g',
        name: 'طاولة',
        hostId: 'host',
        hostName: 'المضيف',
        settings: defaultCreateSettings,
      );
      s = s.copyWith(
        players: [
          ...s.players,
          const Seat(id: 'guest', name: 'ضيف', points: 10, isBot: false),
        ],
      );
      return startMatch(s, Random(1), 0).state;
    }

    test('keeps seat & score while reconnecting, bot after expiry', () {
      var s = playing();
      final hand = s.hands['guest'];
      s = markReconnectingSeat(s, 'guest', 1000).state;
      final guest = s.players.firstWhere((p) => p.id == 'guest');
      expect(guest.reconnecting, isTrue);
      expect(guest.points, 10);
      expect(
        expireGraceSeats(s, nowMillis: 30000, botIdFor: (_) => 'botX'),
        isNull,
      );
      final expired = expireGraceSeats(
        s,
        nowMillis: 61000,
        botIdFor: (_) => 'botX',
      )!.state;
      final bot = expired.players.firstWhere((p) => p.id == 'botX');
      expect(bot.isBot, isTrue);
      expect(bot.points, 10);
      expect(expired.hands['botX'], hand);
      expect(expired.status, 'playing', reason: 'game continues');
    });

    test('rejoin inside the window clears the flag', () {
      var s = playing();
      s = markReconnectingSeat(s, 'guest', 1000).state;
      s = markReconnectedSeat(s, 'guest').state;
      expect(
        s.players.firstWhere((p) => p.id == 'guest').reconnecting,
        isFalse,
      );
      expect(
        expireGraceSeats(s, nowMillis: 999999, botIdFor: (_) => 'x'),
        isNull,
      );
    });

    test('waiting tables remove the expired seat', () {
      var s = newWaitingTable(
        id: 'w',
        name: 'طاولة',
        hostId: 'host',
        hostName: 'المضيف',
        settings: defaultCreateSettings,
      );
      s = s.copyWith(
        players: [
          ...s.players,
          const Seat(id: 'guest', name: 'ضيف', points: 10, isBot: false),
        ],
      );
      s = markReconnectingSeat(s, 'guest', 1).state;
      final out = expireGraceSeats(s, nowMillis: 60001, botIdFor: (_) => 'x');
      expect(out!.state.players.map((p) => p.id), ['host']);
    });

    test('presence diff only drops seats seen before', () {
      final diff = presenceDiff(
        seenBefore: {'a', 'b'},
        now: {'a', 'c'},
        humans: {'a', 'b', 'c'},
      );
      expect(diff.dropped, {'b'});
      expect(diff.returned, {'a', 'c'});
      final fresh = presenceDiff(
        seenBefore: const {},
        now: const {},
        humans: {'a'},
      );
      expect(fresh.dropped, isEmpty);
    });
  });
}
