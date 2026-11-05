import 'package:echo99/game/rules.dart';
import 'package:echo99/services/table_repository.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('host leave deletes the table; guest leave removes self only', () {
    expect(
      tableLeaveAction(hostId: 'host1', playerId: 'host1'),
      TableLeaveAction.deleteTable,
    );
    expect(
      tableLeaveAction(hostId: 'host1', playerId: 'guest9'),
      TableLeaveAction.removeSelf,
    );
    expect(
      tableLeaveAction(hostId: '', playerId: 'guest9'),
      TableLeaveAction.removeSelf,
    );
    expect(
      tableLeaveAction(hostId: 'host1', playerId: ''),
      TableLeaveAction.removeSelf,
    );
  });

  test('tableSubcollections lists log for complete host delete', () {
    expect(TableRepository.tableSubcollections, contains('log'));
    expect(TableRepository.tableSubcollections, isNotEmpty);
  });

  test('english card names use Eastern Arabic digits', () {
    final five = PlayingCard('C', 5);
    expect(five.englishName, '5 of Clubs');
    expect(PlayingCard('S', 11).englishName, 'Jack of Spades');
    expect(PlayingCard('H', 12).englishName, 'Queen of Hearts');
    expect(
      playSpeech('علي', 'Queen of Hearts', 10),
      'علي لعب Queen of Hearts، المجموع أصبح 10',
    );
  });
}
