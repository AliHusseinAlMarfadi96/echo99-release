import 'dart:math';

import 'package:echo99/game/engine.dart';
import 'package:echo99/game/rules.dart';
import 'package:echo99/livekit_token.dart';
import 'package:flutter_test/flutter_test.dart';

MatchState playing({
  required List<Seat> players,
  required Map<String, List<String>> hands,
  int pile = 0,
  int turnIndex = 0,
  int direction = 1,
  List<String> deck = const [],
  bool teamsEnabled = false,
  int timerSeconds = 0,
  String status = 'playing',
}) {
  return MatchState(
    id: 't',
    name: 'طاولة',
    players: players,
    hostId: players.first.id,
    status: status,
    pile: pile,
    lastCard: null,
    turnIndex: turnIndex,
    direction: direction,
    maxPoints: 10,
    timerSeconds: timerSeconds,
    teamsEnabled: teamsEnabled,
    teams: null,
    deck: deck,
    discard: const [],
    hands: hands,
    lastPlay: null,
    cue: null,
    winnerId: null,
    nonce: 0,
    turnStartedAt: 0,
  );
}

void main() {
  const ali = Seat(id: 'a', name: 'علي', points: 10, isBot: false);
  const bot = Seat(id: 'b', name: 'بوت 1', points: 10, isBot: true);
  const third = Seat(id: 'c', name: 'بوت 2', points: 10, isBot: true);

  test('nine adds nothing and speech uses zero', () {
    final result = playCard(
      playing(
        players: [ali, bot],
        hands: {
          'a': ['S9'],
          'b': [],
        },
        pile: 20,
        deck: ['H3'],
      ),
      playerId: 'a',
      cardCode: 'S9',
      random: Random(1),
      nowMillis: 0,
    );
    expect(result.error, isNull);
    expect(result.state.pile, 20);
    expect(result.state.lastCard, 'S9');
    final play = result.state.lastPlay!;
    expect(
      playSpeech(play.name, play.value, play.score),
      'علي لعب 0، المجموع أصبح 20',
    );
  });

  test('two doubles or halves and four reverses only past two players', () {
    final doubled = playCard(
      playing(
        players: [ali, bot],
        hands: {
          'a': ['S2'],
        },
        pile: 20,
      ),
      playerId: 'a',
      cardCode: 'S2',
      random: Random(1),
      nowMillis: 0,
    );
    expect(doubled.state.pile, 40);
    expect(doubled.state.players.first.points, 9);

    final halved = playCard(
      playing(
        players: [ali, bot],
        hands: {
          'a': ['S2'],
        },
        pile: 50,
      ),
      playerId: 'a',
      cardCode: 'S2',
      random: Random(1),
      nowMillis: 0,
    );
    expect(halved.state.pile, 25);
    expect(halved.state.players.first.points, 10);

    final twoPlayers = playCard(
      playing(
        players: [ali, bot],
        hands: {
          'a': ['D4'],
        },
        pile: 10,
      ),
      playerId: 'a',
      cardCode: 'D4',
      random: Random(1),
      nowMillis: 0,
    );
    expect(twoPlayers.state.direction, 1);
    expect(twoPlayers.state.pile, 14);
    expect(twoPlayers.state.cue!.also, contains('ordinary'));
    expect(twoPlayers.state.cue!.also, isNot(contains('reverse')));

    final threePlayers = playCard(
      playing(
        players: [ali, bot, third],
        hands: {
          'a': ['D4'],
          'b': [],
          'c': [],
        },
        pile: 10,
      ),
      playerId: 'a',
      cardCode: 'D4',
      random: Random(1),
      nowMillis: 0,
    );
    expect(threePlayers.state.direction, -1);
    expect(threePlayers.state.turnIndex, 2);
    expect(threePlayers.state.cue!.also, contains('reverse'));
  });

  test('crossing bands and busting past 99', () {
    final band = playCard(
      playing(
        players: [ali, bot],
        hands: {
          'a': ['S5'],
        },
        pile: 30,
      ),
      playerId: 'a',
      cardCode: 'S5',
      random: Random(1),
      nowMillis: 0,
    );
    expect(band.state.pile, 35);
    expect(band.state.players.first.points, 9);

    final bust = playCard(
      playing(
        players: [ali, bot],
        hands: {
          'a': ['H2'],
        },
        pile: 51,
      ),
      playerId: 'a',
      cardCode: 'H2',
      random: Random(1),
      nowMillis: 0,
    );
    expect(bust.state.lastPlay!.score, 102);
    expect(bust.state.players.first.points, 7);
    expect(bust.state.pile, 0);
    expect(bust.state.cue!.type, 'glass');
    expect(bust.state.cue!.also, ['ordinary', 'penalty']);
  });

  test('exact 99 redeals survivors and clashes', () {
    final result = playCard(
      playing(
        players: [ali, bot],
        hands: {
          'a': ['S1'],
          'b': ['H3'],
        },
        pile: 88,
        deck: ['D2'],
      ),
      playerId: 'a',
      cardCode: 'S1',
      choice: 11,
      random: Random(1),
      nowMillis: 0,
    );
    expect(result.state.lastPlay!.outcome, 'exact99');
    expect(result.state.cue!.type, 'metal');
    expect(result.state.cue!.also, isNot(contains('applause')));
    expect(result.state.cue!.also, contains('exact99'));
    expect(result.state.pile, 0);
    expect(result.state.lastPlay!.redealt, isTrue);
    expect(result.state.players[0].points, 10);
    expect(result.state.players[1].points, 8);
    expect(result.state.hands['a']!.length, 4);
    expect(
      playSpeech(
        'علي',
        result.state.lastPlay!.value,
        result.state.lastPlay!.score,
      ),
      'علي لعب 11، المجموع أصبح 99',
    );
  });

  test('zero points eliminates and start rejects the wrong counts', () {
    final eliminated = playCard(
      playing(
        players: [
          const Seat(id: 'a', name: 'علي', points: 2, isBot: false),
          bot,
        ],
        hands: {
          'a': ['H2'],
        },
        pile: 51,
      ),
      playerId: 'a',
      cardCode: 'H2',
      random: Random(1),
      nowMillis: 0,
    );
    expect(eliminated.state.players.first.points, 0);
    expect(eliminated.state.status, 'finished');

    final waiting = playing(players: [ali], hands: const {}, status: 'waiting');
    expect(startMatch(waiting, Random(1), 0).error, playerCountError);
    final five = playing(
      players: [
        ali,
        bot,
        third,
        const Seat(id: 'd', name: 'د', points: 10, isBot: true),
        const Seat(id: 'e', name: 'هـ', points: 10, isBot: true),
      ],
      hands: const {},
      status: 'waiting',
      teamsEnabled: true,
    );
    expect(startMatch(five, Random(1), 0).error, teamsCountError);
    final timed = playing(
      players: [ali, bot],
      hands: const {},
      status: 'waiting',
      timerSeconds: 5,
    );
    expect(startMatch(timed, Random(1), 0).error, timerError);
    final started = startMatch(
      playing(players: [ali, bot], hands: const {}, status: 'waiting'),
      Random(1),
      0,
    );
    expect(started.error, isNull);
    expect(started.state.players.length, 2);
    expect(
      started.state.players.every((seat) => !seat.isBot || seat.id == 'b'),
      isTrue,
    );
    expect(started.state.cue!.type, 'shuffle');
  });

  test('jack gives the same player another turn with two players', () {
    final two = playCard(
      playing(
        players: [ali, bot],
        hands: {
          'a': ['S11'],
        },
        pile: 10,
      ),
      playerId: 'a',
      cardCode: 'S11',
      random: Random(1),
      nowMillis: 0,
    );
    expect(two.error, isNull);
    expect(two.state.pile, 20);
    expect(two.state.turnIndex, 0);
    expect(two.state.current!.id, 'a');
    expect(two.state.cue!.also, contains('jack'));

    final reversed = playCard(
      playing(
        players: [ali, bot],
        hands: {
          'a': ['H11'],
        },
        pile: 4,
        direction: -1,
      ),
      playerId: 'a',
      cardCode: 'H11',
      random: Random(1),
      nowMillis: 0,
    );
    expect(reversed.state.turnIndex, 0);
    expect(reversed.state.direction, -1);
  });

  test('jack skips the immediate next player when three or more play', () {
    final three = playCard(
      playing(
        players: [ali, bot, third],
        hands: {
          'a': ['D11'],
          'b': <String>[],
          'c': <String>[],
        },
        pile: 5,
      ),
      playerId: 'a',
      cardCode: 'D11',
      random: Random(1),
      nowMillis: 0,
    );
    expect(three.state.pile, 15);
    expect(three.state.turnIndex, 2);
    expect(three.state.current!.id, 'c');
    expect(three.state.cue!.also, contains('jack'));
    expect(three.state.cue!.also, isNot(contains('card')));

    final backward = playCard(
      playing(
        players: [ali, bot, third],
        hands: {
          'a': ['C11'],
        },
        pile: 1,
        direction: -1,
      ),
      playerId: 'a',
      cardCode: 'C11',
      random: Random(1),
      nowMillis: 0,
    );
    expect(backward.state.turnIndex, 1);
    expect(backward.state.current!.id, 'b');
  });

  test('landing on 33 or 66 keeps the pile and awards others a loss', () {
    final exact = playCard(
      playing(
        players: [ali, bot],
        hands: {
          'a': ['S3'],
        },
        pile: 30,
      ),
      playerId: 'a',
      cardCode: 'S3',
      random: Random(1),
      nowMillis: 0,
    );
    expect(exact.state.lastPlay!.outcome, 'exact33');
    expect(exact.state.pile, 33);
    expect(exact.state.cue!.also, contains('gain'));
    expect(exact.state.players[1].points, 9);

    final exact66 = playCard(
      playing(
        players: [ali, bot],
        hands: {
          'a': ['S6'],
        },
        pile: 60,
      ),
      playerId: 'a',
      cardCode: 'S6',
      random: Random(1),
      nowMillis: 0,
    );
    expect(exact66.state.lastPlay!.outcome, 'exact66');
    expect(exact66.state.pile, 66);
    expect(exact66.state.players[1].points, 9);

    final band = playCard(
      playing(
        players: [ali, bot, third],
        hands: {
          'a': ['S5'],
        },
        pile: 31,
      ),
      playerId: 'a',
      cardCode: 'S5',
      random: Random(1),
      nowMillis: 0,
    );
    expect(band.state.lastPlay!.outcome, 'band');
    expect(band.state.cue!.also, contains('penalty'));
    expect(band.state.cue!.also, isNot(contains('jack')));
  });

  test('resolvePlay keeps pile on exact 33 and 66, resets only on 99/bust', () {
    final on33 = resolvePlay(before: 30, after: 33, rank: 3, activePlayers: 2);
    expect(on33.nextTotal, 33);
    expect(on33.roundEnded, isFalse);
    expect(on33.outcome, 'exact33');
    expect(on33.othersLoss, 1);

    final on66 = resolvePlay(before: 60, after: 66, rank: 6, activePlayers: 2);
    expect(on66.nextTotal, 66);
    expect(on66.roundEnded, isFalse);

    final on99 = resolvePlay(before: 89, after: 99, rank: 10, activePlayers: 2);
    expect(on99.nextTotal, 0);
    expect(on99.roundEnded, isTrue);
    expect(on99.othersLoss, 2);

    final bust = resolvePlay(
      before: 95,
      after: 105,
      rank: 10,
      activePlayers: 2,
    );
    expect(bust.nextTotal, 0);
    expect(bust.actorLoss, 2);
    expect(bust.outcome, 'bust');
  });

  test('empty secret does not mint and a provided secret does', () {
    expect(
      mintLiveKitToken(
        apiKey: LiveKitConfig.apiKey,
        apiSecret: '',
        identity: 'p',
        displayName: 'علي',
        room: 'room-1',
      ),
      isNull,
    );
    final token = mintLiveKitToken(
      apiKey: LiveKitConfig.apiKey,
      apiSecret: 'unit-test-secret',
      identity: 'p',
      displayName: 'علي',
      room: 'room-1',
    );
    expect(token, isNotNull);
    expect(token!.split('.'), hasLength(3));
  });

  test('host is always first after deal and after exact99 redeal', () {
    const host = Seat(id: 'a', name: 'علي', points: 10, isBot: false);
    const guest = Seat(id: 'b', name: 'ضيف', points: 10, isBot: false);
    // Guest is at turnIndex 1 and scores exact 99 — host must still lead redeal.
    final result = playCard(
      playing(
        players: [host, guest],
        hands: {
          'a': ['H3'],
          'b': ['S1'],
        },
        pile: 88,
        turnIndex: 1,
        deck: ['D2', 'D3', 'D4', 'D5', 'D6', 'D7', 'D8', 'D9'],
      ),
      playerId: 'b',
      cardCode: 'S1',
      choice: 11,
      random: Random(1),
      nowMillis: 0,
    );
    expect(result.state.lastPlay!.outcome, 'exact99');
    expect(result.state.lastPlay!.redealt, isTrue);
    expect(result.state.current!.id, 'a');
    expect(result.state.turnIndex, 0);

    final started = startMatch(
      playing(players: [host, guest], hands: const {}, status: 'waiting'),
      Random(2),
      0,
    );
    expect(started.error, isNull);
    expect(started.state.current!.id, 'a');
  });
}
