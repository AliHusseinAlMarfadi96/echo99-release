import 'dart:io';
import 'dart:math';

import 'package:echo99/game/engine.dart';
import 'package:echo99/game/jackaroo.dart';
import 'package:echo99/game/lifecycle.dart';
import 'package:echo99/game/ludo.dart';
import 'package:echo99/game/snakes.dart';
import 'package:echo99/game/thousand_miles.dart';
import 'package:echo99/services/sound_durations.dart';
import 'package:echo99/services/sounds.dart';
import 'package:flutter_test/flutter_test.dart';

MatchState _two(String game) {
  var state = newWaitingTable(
    id: 't',
    name: 'طاولة',
    hostId: 'A',
    hostName: 'A',
    settings: const TableSettings(startPoints: 10, timerSeconds: 0),
    game: game,
  );
  state = addBot(state, 'B', 'B').state;
  return state;
}

MatchState _ludo({
  required List<int> a,
  required List<int> b,
  Map<String, dynamic> extra = const {},
}) {
  final s = _two(gameLudo);
  return MatchState.fromMap({
    ...s.toMap(),
    'status': 'playing',
    'turnIndex': 0,
    'board': {
      'ludoMode': ludoModeNormal,
      'safeSquares': true,
      'colors': {'A': 0, 'B': 1},
      'pieces': {'A': a, 'B': b},
      'phase': 'roll',
      ...extra,
    },
  }, 't');
}

MatchState _miles({
  required List<String> handA,
  List<String> handB = const ['25_miles'],
  Map<String, dynamic>? carA,
  Map<String, dynamic>? carB,
  Map<String, dynamic> settings = const {},
  List<String>? deck,
  String phase = 'play',
}) {
  final s = startGame(_two(gameThousandMiles), Random(3), 0).state;
  Map<String, dynamic> car([Map<String, dynamic>? over]) => {
    'miles': 0,
    'go': true,
    'faults': <String>[],
    'speedLimit': false,
    'counterflow': false,
    'safeties': <String>[],
    'score': 0,
    'used200': 0,
    'arrived': false,
    ...?over,
  };
  return MatchState.fromMap({
    ...s.toMap(),
    'turnIndex': 0,
    'hands': {'A': handA, 'B': handB},
    'deck': ?deck,
    'board': {
      ...s.board,
      ...settings,
      'phase': phase,
      'coup': null,
      'cars': {'A': car(carA), 'B': car(carB)},
    },
  }, 't');
}

MatchState _jackaroo({
  required List<int> a,
  required List<String> handA,
  int sixChain = 0,
}) {
  var state = _two(gameJackaroo);
  state = applyJackarooMode(state, jackarooStandard, 0).state;
  state = startGame(state, Random(2), 0).state;
  return MatchState.fromMap({
    ...state.toMap(),
    'turnIndex': 0,
    'hands': {
      'A': handA,
      'B': ['H2', 'H3'],
    },
    'board': {
      'mode': jackarooStandard,
      'colors': {'A': 0, 'B': 1},
      'pieces': {
        'A': a,
        'B': [jackarooHome, jackarooHome, jackarooHome, jackarooHome],
      },
      'sixChain': sixChain,
    },
  }, 't');
}

void main() {
  group('Ludo', () {
    test(
      'safe squares are 1, 9, 14, 22, 27, 35, 40, 48 (1-based) and toggle',
      () {
        const on = LudoSettings();
        const off = LudoSettings(safeSquares: false);
        final oneBased = [
          for (var i = 0; i < ludoTrack; i++)
            if (ludoIsSafeSquare(i, on)) i + 1,
        ];
        expect(oneBased, [1, 9, 14, 22, 27, 35, 40, 48]);
        expect([
          for (var i = 0; i < ludoTrack; i++) ludoIsSafeSquare(i, off),
        ], everyElement(isFalse));
        // Free mode honours the toggle too.
        expect(ludoIsSafeSquare(8, on.withMode(ludoModeFree)), isTrue);
      },
    );

    test('no capture on a safe square', () {
      // A (red, base 0) at progress 5 rolls 3 → absolute 8 = «الخانة 9، آمنة».
      // B (blue, base 26) sits on absolute 8 = progress 34.
      final s = _ludo(
        a: [5, -1, -1, -1],
        b: [34, -1, -1, -1],
        extra: {'phase': 'move', 'pendingRoll': 3},
      );
      final r = moveLudo(s, playerId: 'A', piece: 0, nowMillis: 1);
      expect(r.error, isNull);
      expect(ludoPieces(r.state)['B']![0], 34, reason: 'safe square');
      expect(r.state.cue!.also, isNot(contains('ludo/eat')));
    });

    test('capture plays «eat» exactly once, at the end of the movement', () {
      // A at progress 5 rolls 4 → absolute 9 (not safe); B on 9 = progress 35.
      final s = _ludo(
        a: [5, -1, -1, -1],
        b: [35, -1, -1, -1],
        extra: {'phase': 'move', 'pendingRoll': 4},
      );
      final r = moveLudo(s, playerId: 'A', piece: 0, nowMillis: 1);
      expect(r.error, isNull);
      expect(ludoPieces(r.state)['B']![0], ludoHomeYard);
      final clips = r.state.cue!.also;
      expect(clips.where((c) => c == 'ludo/eat'), hasLength(1));
      expect(clips.last, 'ludo/eat');
      // One step pulse per square before it (red = team 1 → dice_move).
      expect(clips.sublist(0, 4), List.filled(4, 'ludo/dice_move'));
    });

    test('three consecutive 6s end the turn', () {
      final s = _ludo(
        a: [5, -1, -1, -1],
        b: [-1, -1, -1, -1],
        extra: {'consecutiveSixes': 2},
      );
      final r = rollLudo(s, playerId: 'A', roll: 6, nowMillis: 1);
      expect(r.error, isNull);
      expect(r.state.current!.id, 'B');
      expect(r.state.cue!.also, contains('ludo/three_six'));
      expect(r.state.cue!.also.first, 'ludo/dice_roll');
    });

    test('after a roll the text names the legal moves', () {
      final s = _ludo(a: [5, -1, -1, -1], b: [-1, -1, -1, -1]);
      final r = rollLudo(s, playerId: 'A', roll: 2, nowMillis: 1);
      final text = '${r.state.board['text']}';
      expect(text, contains('2'));
      expect(text, contains('الأحمر قطعة 1'));
    });

    test('piece label: color + number + square + safety', () {
      final s = _ludo(a: [13, -1, -1, -1], b: [-1, -1, -1, -1]);
      expect(ludoPieceLabel(s, 'A', 0), 'الأحمر قطعة 1، الخانة 14، آمنة');
      expect(ludoPieceLabel(s, 'A', 1), 'الأحمر قطعة 2، في القاعدة');
    });
  });

  group('Thousand Miles (PDF)', () {
    test('deck has 121 cards with the PDF counts', () {
      final deck = milesFreshDeck();
      int n(String c) => deck.where((x) => x == c).length;
      expect(deck, hasLength(121));
      expect(n('25_miles'), 10);
      expect(n('50_miles'), 10);
      expect(n('75_miles'), 10);
      expect(n('100_miles'), 12);
      expect(n('200_miles'), 4);
      expect(n('red_light'), 5);
      expect(n('speed_limit'), 4);
      expect(n('out_of_gas'), 3);
      expect(n('flat'), 3);
      expect(n('accident'), 3);
      expect(n('counterflow'), 6);
      expect(n('green_light'), 14);
      expect(n('end_of_speed_limit'), 6);
      expect(n('gas'), 6);
      expect(n('spare_tire'), 6);
      expect(n('repairs'), 6);
      expect(n('end_of_counterflow'), 9);
      for (final s in milesSafeties) {
        expect(n(s), 1);
      }
    });

    test('every card has its sound in assets/sounds/miles', () {
      for (final code in milesFreshDeck().toSet()) {
        expect(
          File('assets/sounds/miles/$code.mp3').existsSync(),
          isTrue,
          reason: code,
        );
      }
    });

    test('coup fourré cancels the attack and scores 400', () {
      final s = _miles(
        handA: ['red_light', '25_miles'],
        handB: ['right_of_way', '50_miles'],
        carB: {'miles': 100},
      );
      final attacked = playMiles(
        s,
        playerId: 'A',
        card: 'red_light',
        targetId: 'B',
        discardOnly: false,
        random: Random(1),
        nowMillis: 10,
      );
      expect(attacked.error, isNull);
      expect(milesCoupHolders(attacked.state), ['B']);
      expect(milesCar(attacked.state, 'B')['faults'], contains('red_light'));
      final coup = coupFourreMiles(
        attacked.state,
        playerId: 'B',
        card: 'right_of_way',
        random: Random(1),
        nowMillis: 20,
      );
      expect(coup.error, isNull);
      final car = milesCar(coup.state, 'B');
      expect(car['score'], 400);
      expect(car['faults'], isEmpty);
      expect(car['safeties'], contains('right_of_way'));
      expect(coup.state.current!.id, 'B', reason: 'coup player takes a turn');
      expect(coup.state.board['coup'], isNull);
    });

    test('auto-draw: card sound, then the draw sound, next hand refilled', () {
      final s = _miles(
        handA: ['25_miles', '50_miles'],
        handB: ['100_miles'],
        settings: {'autoDraw': true},
        deck: ['gas', 'repairs', 'flat'],
      );
      final r = playMiles(
        s,
        playerId: 'A',
        card: '25_miles',
        discardOnly: false,
        random: Random(1),
        nowMillis: 1,
      );
      expect(r.error, isNull);
      final clips = r.state.cue!.also;
      expect(clips, contains('miles/25_miles'));
      expect(clips.last, 'miles/draw');
      expect(
        clips.indexOf('miles/draw'),
        greaterThan(clips.indexOf('miles/25_miles')),
      );
      expect(r.state.current!.id, 'B');
      expect(r.state.board['phase'], 'play');
      expect(r.state.hands['B'], hasLength(2));
      expect(milesCar(r.state, 'A')['miles'], 25);
    });

    test('exactly 1000: overshooting is refused, the exact card arrives', () {
      final s = _miles(
        handA: ['50_miles', '25_miles'],
        carA: {'miles': 975},
        deck: ['gas', 'repairs'],
      );
      expect(milesPlayError(s, 'A', '50_miles'), isNotNull);
      final over = playMiles(
        s,
        playerId: 'A',
        card: '50_miles',
        discardOnly: false,
        random: Random(1),
        nowMillis: 1,
      );
      expect(over.error, isNotNull);
      final exact = playMiles(
        s,
        playerId: 'A',
        card: '25_miles',
        discardOnly: false,
        random: Random(1),
        nowMillis: 1,
      );
      expect(exact.error, isNull);
      expect(exact.state.cue!.also, contains('exact99'));
    });

    test('a stopped car cannot be attacked unless stacking is on', () {
      final s = _miles(handA: ['flat'], carB: {'go': false, 'miles': 50});
      expect(milesLegalTargets(s, 'A', 'flat'), isEmpty);
      final stacked = _miles(
        handA: ['flat'],
        carB: {'go': false, 'miles': 50},
        settings: {'stackHazards': true},
      );
      expect(milesLegalTargets(stacked, 'A', 'flat'), ['B']);
    });
  });

  group('Jackaroo 6', () {
    test('a 6 is a plain 6-step walk: no exit, no replay (rules PDF)', () {
      const h = jackarooHome;
      final s = _jackaroo(a: [h, h, 20, h], handA: ['S6', 'H9']);
      final moves = jackarooMovesForCard(s, 'A', 'S6');
      expect(moves.where((m) => m.kind == 'exit'), isEmpty);
      final walk = moves.singleWhere(
        (m) => m.kind == 'forward' && m.piece == 2 && m.steps == 6,
      );
      final r = playJackaroo(
        s,
        playerId: 'A',
        move: walk,
        random: Random(1),
        nowMillis: 1,
      );
      expect(r.error, isNull);
      expect(r.state.current!.id, 'B', reason: 'turn passes after a 6');
      expect(jackarooSixChain(r.state), 0);
    });

    test('a 6 never forfeits the turn, even after earlier sixes', () {
      const h = jackarooHome;
      final s = _jackaroo(a: [h, h, 20, h], handA: ['S6', 'H9'], sixChain: 2);
      final moves = jackarooMovesForCard(s, 'A', 'S6');
      expect(moves.where((m) => m.kind == 'sixForfeit'), isEmpty);
      expect(moves.where((m) => m.kind == 'forward'), isNotEmpty);
    });

  group('Jackaroo rules PDF conformity', () {
    MatchState jk({
      required List<int> a,
      required List<int> b,
      required List<String> handA,
      List<String> handB = const ['H2', 'H3'],
      bool complex = false,
    }) {
      var state = _two(gameJackaroo);
      state = applyJackarooMode(
        state,
        complex ? jackarooComplex : jackarooStandard,
        0,
      ).state;
      state = startGame(state, Random(2), 0).state;
      return MatchState.fromMap({
        ...state.toMap(),
        'turnIndex': 0,
        'hands': {'A': handA, 'B': handB},
        'board': {
          'mode': complex ? jackarooComplex : jackarooStandard,
          'colors': {'A': 0, 'B': 1},
          'pieces': {'A': a, 'B': b},
          'sixChain': 0,
        },
      }, 't');
    }

    test('blocked on track: burn one chosen card, not the whole hand', () {
      const h = jackarooHome;
      // A's only track piece sits at 75; a 6 overshoots the safe lane end.
      final s = jk(a: [75, h, h, h], b: [h, h, h, h], handA: ['S6', 'H6']);
      final moves = jackarooLegalMoves(s, 'A');
      expect(moves.map((m) => m.kind).toSet(), {'burn'});
      expect(moves, hasLength(2));
      final r = playJackaroo(
        s,
        playerId: 'A',
        move: moves.first,
        random: Random(1),
        nowMillis: 1,
      );
      expect(r.error, isNull);
      expect(r.state.hands['A']!.length, 1, reason: 'only the burned card');
      expect(r.state.cue!.also, ['jk_burn_cards']);
      expect(r.state.current!.id, 'B');
    });

    test('all pieces in base with no exit card: the whole hand burns', () {
      const h = jackarooHome;
      final s = jk(a: [h, h, h, h], b: [h, h, h, h], handA: ['S6', 'H9']);
      final moves = jackarooLegalMoves(s, 'A');
      expect(moves.single.kind, 'burnAll');
      final r = playJackaroo(
        s,
        playerId: 'A',
        move: moves.single,
        random: Random(1),
        nowMillis: 1,
      );
      expect(r.error, isNull);
      expect(r.state.hands['A'], isEmpty);
      expect(r.state.cue!.also, ['jk_burn_all']);
    });

    test('complex 10 forces a burn only when another player holds cards', () {
      const h = jackarooHome;
      final withCards = jk(
        a: [10, h, h, h],
        b: [h, h, h, h],
        handA: ['S10'],
        handB: ['H2'],
        complex: true,
      );
      expect(
        jackarooMovesForCard(withCards, 'A', 'S10').map((m) => m.kind),
        contains('burnNext'),
      );
      final noCards = jk(
        a: [10, h, h, h],
        b: [h, h, h, h],
        handA: ['S10'],
        handB: [],
        complex: true,
      );
      expect(
        jackarooMovesForCard(noCards, 'A', 'S10').map((m) => m.kind),
        isNot(contains('burnNext')),
      );
    });

    test('complex king sweep returns own stones on its path', () {
      const h = jackarooHome;
      final s = jk(
        a: [10, 15, h, h],
        b: [h, h, h, h],
        handA: ['S13'],
        complex: true,
      );
      final moves = jackarooMovesForCard(s, 'A', 'S13');
      final walk = moves.singleWhere(
        (m) => m.kind == 'forward' && m.piece == 0,
      );
      final r = playJackaroo(
        s,
        playerId: 'A',
        move: walk,
        random: Random(1),
        nowMillis: 1,
      );
      expect(r.error, isNull);
      final board = JackarooBoard.of(r.state);
      expect(board.pieces['A']![0], 23);
      expect(
        board.pieces['A']![1],
        jackarooHome,
        reason: 'swept own stone returns home',
      );
    });

    test('normal king walk is not offered; complex 5 cannot home an enemy', () {
      const h = jackarooHome;
      final normal = jk(a: [10, h, h, h], b: [h, h, h, h], handA: ['S13']);
      expect(
        jackarooMovesForCard(normal, 'A', 'S13').map((m) => m.kind).toSet(),
        {'exit'},
      );
      final s = jk(
        a: [30, h, h, h],
        b: [73, h, h, h],
        handA: ['S5'],
        complex: true,
      );
      final moves = jackarooMovesForCard(s, 'A', 'S5');
      expect(moves.where((m) => m.owner == 'B'), isEmpty);
      expect(moves.where((m) => m.owner == 'A'), isNotEmpty);
    });
  });

      test('forward steps pulse per square, team colors alternate clips', () {
      expect(
        jackarooStepSounds(3, colorIndex: 0),
        List.filled(3, 'jk_step1'),
      );
      expect(jackarooStepSounds(2, colorIndex: 1), List.filled(2, 'jk_step2'));
    });
  });

  group('Snakes and Ladders audio', () {
    test('roll once, one step per square, ladder right after', () {
      final clips = snakesSounds(snakesMove(3, 1));
      expect(clips, [snakesRollSound, snakesDingSound, snakesLadderSound]);
      final snake = snakesSounds(snakesMove(11, 6));
      expect(snake.first, snakesRollSound);
      expect(snake.where((c) => c == snakesRollSound), hasLength(1));
      expect(snake.where((c) => c == snakesDingSound), hasLength(6));
      expect(snake.last, snakesSnakeSound);
    });

    test('step pulses are 250 ms apart and never overlap', () {
      final plan = planSequence([
        snakesRollSound,
        ...List.filled(4, snakesDingSound),
        snakesLadderSound,
      ]);
      for (var i = 1; i < plan.length; i++) {
        final prev = plan[i - 1];
        final prevLen = soundDurationsMs[prev.name] ?? 0;
        expect(plan[i].startMs - prev.startMs, greaterThanOrEqualTo(250));
        expect(plan[i].startMs, greaterThanOrEqualTo(prev.startMs + prevLen));
      }
      // Short step clips sit exactly on the 250 ms grid.
      expect(plan[2].startMs - plan[1].startMs, 250);
    });

    test('start cue is the game-start sound', () {
      final s = startGame(_two(gameSnakes), Random(1), 0).state;
      expect(s.cue!.also, [snakesStartSound]);
    });
  });
}
