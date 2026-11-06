import 'dart:math';

import 'package:echo99/game/engine.dart';
import 'package:echo99/game/sound_routing.dart';
import 'package:flutter_test/flutter_test.dart';

MatchState table({
  required List<Seat> players,
  required Map<String, List<String>> hands,
  int pile = 0,
  int maxPoints = 10,
}) {
  return MatchState(
    id: 't',
    name: 'طاولة',
    players: players,
    hostId: players.first.id,
    status: 'playing',
    pile: pile,
    lastCard: null,
    turnIndex: 0,
    direction: 1,
    maxPoints: maxPoints,
    timerSeconds: 0,
    teamsEnabled: false,
    teams: null,
    deck: const ['D4', 'D5', 'D6', 'D7'],
    discard: const [],
    hands: hands,
    lastPlay: null,
    cue: null,
    winnerId: null,
    nonce: 0,
    turnStartedAt: 0,
  );
}

MatchState play(MatchState state, String card, {int? choice}) {
  final result = playCard(
    state,
    playerId: state.current!.id,
    cardCode: card,
    choice: choice,
    random: Random(1),
    nowMillis: 0,
  );
  expect(result.error, isNull);
  return result.state;
}

void main() {
  const a = Seat(id: 'a', name: 'علي', points: 10, isBot: false);
  const b = Seat(id: 'b', name: 'بوت 1', points: 10, isBot: true);
  const c = Seat(id: 'c', name: 'بوت 2', points: 10, isBot: true);

  void expectNoEndGame(List<String> clips) {
    expect(clips.where(endGameSounds.contains), isEmpty);
    expect(clips, isNot(contains('loss1')));
    expect(clips, isNot(contains('loss2')));
    expect(clips, isNot(contains('applause')));
    expect(clips, isNot(contains('bust99')));
  }

  test('crossing 33 upward plays exactly the point-loss sound', () {
    final before = table(
      players: [a, b, c],
      hands: {
        'a': ['S5'],
      },
      pile: 31,
    );
    final after = play(before, 'S5');
    expect(after.players.first.points, 9);
    for (final me in ['a', 'b', 'c']) {
      final clips = tableSounds(prev: before, next: after, me: me);
      expect(clips, [pointLossSound]);
      expectNoEndGame(clips);
    }
  });

  test('crossing 66 upward plays exactly the point-loss sound', () {
    final before = table(
      players: [a, b],
      hands: {
        'a': ['S7'],
      },
      pile: 63,
    );
    final after = play(before, 'S7');
    expect(tableSounds(prev: before, next: after, me: 'a'), [pointLossSound]);
  });

  test('landing exactly on 33 or 66 plays exactly the point-gain sound', () {
    final on33 = table(
      players: [a, b],
      hands: {
        'a': ['S3'],
      },
      pile: 30,
    );
    final next33 = play(on33, 'S3');
    expect(next33.pile, 33);
    expect(tableSounds(prev: on33, next: next33, me: 'b'), [pointGainSound]);

    final on66 = table(
      players: [a, b],
      hands: {
        'a': ['S6'],
      },
      pile: 60,
    );
    final next66 = play(on66, 'S6');
    expect(next66.pile, 66);
    expect(tableSounds(prev: on66, next: next66, me: 'a'), [pointGainSound]);
  });

  test('a two-point bust past 99 has no laughter, glass, or applause', () {
    final before = table(
      players: [a, b],
      hands: {
        'a': ['H2'],
      },
      pile: 51,
    );
    final after = play(before, 'H2');
    expect(after.players.first.points, 7);
    final clips = tableSounds(prev: before, next: after, me: 'a');
    // Bust costs 2 points and (per PDF) redeals — penalty plus the deal.
    expect(clips, [pointLossSound, 'deal']);
    expectNoEndGame(clips);
  });

  test('exact 99 mid-match is not applause', () {
    final before = table(
      players: [a, b],
      hands: {
        'a': ['S1'],
        'b': ['H3'],
      },
      pile: 88,
    );
    final after = play(before, 'S1', choice: 11);
    final clips = tableSounds(prev: before, next: after, me: 'a');
    expect(clips.first, exact99Sound);
    expectNoEndGame(clips);
  });

  test('an older build cue with laughter is ignored for a point loss', () {
    final before = table(
      players: [a, b],
      hands: {
        'a': ['S5'],
      },
      pile: 31,
    );
    final after = play(before, 'S5');
    final legacy = MatchState.fromMap({
      ...after.toMap(),
      'cue': {
        'type': 'play',
        'nonce': after.cue!.nonce,
        'also': ['ordinary', 'penalty', 'loss1'],
      },
    }, 't');
    expect(tableSounds(prev: before, next: legacy, me: 'b'), [pointLossSound]);
  });

  test('reaching 0 ends the match with the loss and win end sounds', () {
    const last = Seat(id: 'a', name: 'علي', points: 1, isBot: false);
    final before = table(
      players: [last, b],
      hands: {
        'a': ['S5'],
      },
      pile: 31,
    );
    final after = play(before, 'S5');
    expect(after.players.first.points, 0);
    expect(after.status, 'finished');
    expect(tableSounds(prev: before, next: after, me: 'a'), [matchLossSound]);
    expect(tableSounds(prev: before, next: after, me: 'b'), [matchWinSound]);
  });

  test('reaching 0 while the match continues', () {
    const last = Seat(id: 'a', name: 'علي', points: 1, isBot: false);
    final before = table(
      players: [last, b, c],
      hands: {
        'a': ['S5'],
      },
      pile: 31,
    );
    final after = play(before, 'S5');
    expect(after.status, 'playing');
    expect(tableSounds(prev: before, next: after, me: 'a'), [matchLossSound]);
    expect(tableSounds(prev: before, next: after, me: 'b'), [eliminatedSound]);
  });

  test('playSound never routes a point event to an end-game clip', () {
    for (final outcome in ['band', 'bust', 'exact33', 'exact66', 'exact99']) {
      expect(endGameSounds.contains(playSound(outcome)), isFalse);
    }
  });
}
