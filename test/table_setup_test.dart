import 'dart:math';

import 'package:echo99/game/engine.dart';
import 'package:echo99/game/rules.dart';
import 'package:echo99/services/local_match.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const settings = TableSettings(startPoints: 15, timerSeconds: 0);

  test('offline and online tables start with exactly the host', () {
    final offline = localWaitingTable(
      playerId: 'me',
      playerName: 'علي',
      settings: settings,
    );
    expect(offline.players.length, 1);
    expect(offline.players.single.id, 'me');
    expect(offline.players.single.isBot, isFalse);
    expect(offline.status, 'waiting');

    final online = newWaitingTable(
      id: 'x',
      name: 'طاولة',
      hostId: 'host',
      hostName: 'المضيف',
      settings: settings,
    );
    expect(online.players.map((s) => s.id), ['host']);
    expect(online.players.any((s) => s.isBot), isFalse);
  });

  test('starting alone is rejected with the Arabic player count message', () {
    final alone = localWaitingTable(
      playerId: 'me',
      playerName: 'علي',
      settings: settings,
    );
    final result = startMatch(alone, Random(1), 0);
    expect(result.error, playerCountError);
    expect(playerCountError, 'تتطلب هذه اللعبة من 2 إلى 10 لاعبين');
    expect(result.state.players.length, 1);
  });

  test('bots only come from addBot and a redeal adds none', () {
    var state = localWaitingTable(
      playerId: 'me',
      playerName: 'علي',
      settings: settings,
    );
    state = addBot(state, nextLocalBotId(state), nextBotName(state)).state;
    expect(state.players.length, 2);
    expect(state.players.last.isBot, isTrue);
    final started = startMatch(state, Random(1), 0).state;
    expect(started.players.length, 2);
    expect(started.players.every((s) => s.points == 15), isTrue);
    final current = started.current!;
    final hand = {
      ...started.hands,
      current.id: ['S1'],
    };
    final at88 = MatchState.fromMap({
      ...started.toMap(),
      'pile': 88,
      'hands': hand,
    }, started.id);
    final redealt = playCard(
      at88,
      playerId: current.id,
      cardCode: 'S1',
      choice: 11,
      random: Random(1),
      nowMillis: 0,
    ).state;
    expect(redealt.lastPlay!.redealt, isTrue);
    expect(redealt.players.length, 2);
  });

  test('starting points accept any 1..99 value and reject others', () {
    for (final text in ['9', '10', '15', '20', '1', '99']) {
      final parsed = parseTableSettings(
        startPointsText: text,
        timerEnabled: false,
        timerText: '',
      );
      expect(parsed.error, isNull, reason: text);
      expect(parsed.settings!.startPoints, int.parse(text));
    }
    for (final text in ['0', '100', '', 'x']) {
      final parsed = parseTableSettings(
        startPointsText: text,
        timerEnabled: false,
        timerText: '',
      );
      expect(parsed.error, startPointsError, reason: text);
    }
  });

  test('timer switch off disables the timer; on requires 10 seconds', () {
    final off = parseTableSettings(
      startPointsText: '10',
      timerEnabled: false,
      timerText: '5',
    );
    expect(off.settings!.timerSeconds, 0);
    expect(off.settings!.timerEnabled, isFalse);

    final short = parseTableSettings(
      startPointsText: '10',
      timerEnabled: true,
      timerText: '9',
    );
    expect(short.error, timerError);

    final on = parseTableSettings(
      startPointsText: '10',
      timerEnabled: true,
      timerText: '10',
    );
    expect(on.settings!.timerSeconds, 10);
  });

  test('host settings apply before the start and set seat points', () {
    var state = localWaitingTable(
      playerId: 'me',
      playerName: 'علي',
      settings: settings,
    );
    state = applySettings(
      state,
      const TableSettings(startPoints: 20, timerSeconds: 15),
    ).state;
    expect(state.maxPoints, 20);
    expect(state.timerSeconds, 15);
    expect(state.players.single.points, 20);
    final bad = applySettings(
      state,
      const TableSettings(startPoints: 0, timerSeconds: 0),
    );
    expect(bad.error, startPointsError);
    final synced = MatchState.fromMap(state.toMap(), state.id);
    expect(synced.maxPoints, 20);
    expect(synced.timerSeconds, 15);
  });
}
