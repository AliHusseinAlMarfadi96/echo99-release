import 'package:echo99/game/engine.dart';
import 'package:flutter_test/flutter_test.dart';

MatchState finished({String? winnerId, List<List<String>>? teams}) {
  return MatchState(
    id: 'localmatch',
    name: 't',
    players: const [
      Seat(id: 'me', name: 'أنا', points: 1, isBot: false),
      Seat(id: 'bot1', name: 'بوت', points: 0, isBot: true),
    ],
    hostId: 'me',
    status: 'finished',
    pile: 0,
    lastCard: null,
    turnIndex: 0,
    direction: 1,
    maxPoints: 10,
    timerSeconds: 0,
    teamsEnabled: teams != null,
    teams: teams,
    deck: const [],
    discard: const [],
    hands: const {},
    lastPlay: null,
    cue: null,
    winnerId: winnerId,
    nonce: 1,
    turnStartedAt: 0,
  );
}

void main() {
  test('win and loss follow the survivor, including a teammate', () {
    expect(playerWonMatch(finished(winnerId: 'me'), 'me'), isTrue);
    expect(playerWonMatch(finished(winnerId: 'bot1'), 'me'), isFalse);
    expect(playerWonMatch(finished(winnerId: null), 'me'), isFalse);
    expect(
      playerWonMatch(
        finished(
          winnerId: 'ally',
          teams: const [
            ['me', 'ally'],
            ['bot1'],
          ],
        ),
        'me',
      ),
      isTrue,
    );
  });
}
