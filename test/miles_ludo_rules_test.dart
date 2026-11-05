import 'dart:math';

import 'package:echo99/game/engine.dart';
import 'package:echo99/game/ludo.dart';
import 'package:echo99/game/thousand_miles.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('miles deck is 121', () {
    expect(milesFreshDeck().length, 121);
  });

  test('miles player counts', () {
    // PDF: individual 2–6; teams 4, 6, 8 or 9; 7 never.
    expect(milesPlayerCountOk(7), isFalse);
    expect(milesPlayerCountOk(7, teams: true), isFalse);
    expect(milesPlayerCountOk(4), isTrue);
    expect(milesPlayerCountOk(6), isTrue);
    expect(milesPlayerCountOk(9), isFalse);
    expect(milesPlayerCountOk(9, teams: true), isTrue);
    expect(milesPlayerCountOk(8, teams: true), isTrue);
    expect(milesPlayerCountOk(5, teams: true), isFalse);
  });

  test('ludo positions name color, piece, square and safety', () {
    final state = MatchState(
      id: 't',
      name: 't',
      players: const [
        Seat(id: 'a', name: 'A', points: 1, isBot: false),
        Seat(id: 'b', name: 'B', points: 1, isBot: false),
      ],
      hostId: 'a',
      status: 'playing',
      pile: 0,
      lastCard: null,
      turnIndex: 0,
      direction: 1,
      maxPoints: 1,
      timerSeconds: 0,
      teamsEnabled: false,
      teams: null,
      deck: const [],
      discard: const [],
      hands: const {},
      lastPlay: null,
      cue: null,
      winnerId: null,
      nonce: 1,
      turnStartedAt: 0,
      game: gameLudo,
      board: {
        'ludoMode': ludoModeNormal,
        'safeSquares': true,
        'colors': {'a': 0, 'b': 1},
        'pieces': {
          'a': [0, -1, -1, -1],
          'b': [-1, -1, -1, -1],
        },
      },
    );
    final text = ludoPositionsText(state);
    // Piece 1 of red on its start square = «الخانة 1، آمنة».
    expect(text, contains('الأحمر قطعة 1، الخانة 1، آمنة'));
    expect(text, contains('في القاعدة'));
  });

  test('start miles deals 6', () {
    final waiting = MatchState(
      id: 't',
      name: 't',
      players: const [
        Seat(id: 'a', name: 'A', points: 1, isBot: false),
        Seat(id: 'b', name: 'B', points: 1, isBot: false),
      ],
      hostId: 'a',
      status: 'waiting',
      pile: 0,
      lastCard: null,
      turnIndex: 0,
      direction: 1,
      maxPoints: 5000,
      timerSeconds: 0,
      teamsEnabled: false,
      teams: null,
      deck: const [],
      discard: const [],
      hands: const {},
      lastPlay: null,
      cue: null,
      winnerId: null,
      nonce: 0,
      turnStartedAt: 0,
      game: gameThousandMiles,
      board: const {},
    );
    final r = startMiles(waiting, Random(1), 1);
    expect(r.error, isNull);
    expect(r.state.hands['a']!.length, 6);
    expect(r.state.deck.length, 121 - 12);
  });
}
