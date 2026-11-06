import 'package:echo99/game/engine.dart';
import 'package:echo99/game/jackaroo.dart';
import 'package:echo99/services/table_event_audio.dart';
import 'package:echo99/services/table_repository.dart';
import 'package:flutter_test/flutter_test.dart';

TableLogEntry message(String id, String author, {String kind = 'chat'}) =>
    TableLogEntry(
      id: id,
      kind: kind,
      text: 'message',
      atMillis: 1,
      authorId: author,
    );

MatchState table() => newWaitingTable(
  id: 't',
  name: 'table',
  hostId: 'me',
  hostName: 'me',
  settings: const TableSettings(startPoints: 10, timerSeconds: 0),
);

void main() {
  test(
    'recipient alerts only on new chat, never history, own echo, or play log',
    () {
      final audio = TableChatAudio();
      final old = message('old', 'other');
      expect(audio.update([old], me: 'me'), isEmpty);
      expect(audio.update([old], me: 'me'), isEmpty);
      final own = message('own', 'me');
      final play = message('play', 'other', kind: 'play');
      expect(audio.update([old, own, play], me: 'me'), isEmpty);
      final remote = message('new', 'other');
      expect(audio.update([old, own, play, remote], me: 'me'), ['alert']);
      expect(audio.update([old, own, play, remote], me: 'me'), isEmpty);
      expect(
        audio.update([
          old,
          own,
          play,
          remote,
          message('unknown', ''),
        ], me: 'me'),
        isEmpty,
      );
    },
  );
  test('membership cues use named join and leave, rename stays alert', () {
    final before = table();
    final after = addBot(before, 'bot', 'Bot').state;
    expect(tableSeatAudio(before, after, 'me'), ['join']);
    expect(tableSeatAudio(after, after, 'me'), isEmpty);
    expect(tableSeatAudio(after, before, 'me'), ['leave_table']);
    final renamed = after.copyWith(
      players: [
        after.players.first,
        after.players.last.copyWith(name: 'Renamed'),
      ],
    );
    expect(tableSeatAudio(after, renamed, 'me'), ['alert']);
  });
  test(
    'ordinary Jackaroo landing follows every step, not instead of a step',
    () {
      final board = JackarooBoard(
        mode: jackarooStandard,
        colors: {'me': 0, 'other': 1},
        pieces: {
          'me': [10, -1, -1, -1],
          'other': [-1, -1, -1, -1],
        },
      );
      final moved = jackarooAdvance(board, 'me', 0, 3);
      expect(moved, isNotNull);
      expect(moved!.sounds, [
        'jk_step1',
        'jk_step1',
        'jk_step1',
        'jk_marble_land',
      ]);
      expect(moved.board.pieces['me']!.first, 13);
    },
  );
}
