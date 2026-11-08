import 'dart:async';
import 'dart:io';

import 'package:echo99/services/sound_player.dart';
import 'package:echo99/services/sounds.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fake_async/fake_async.dart';

class FakePlayer implements SoundPlayer {
  final events = <String>[];
  final end = StreamController<void>.broadcast(sync: true);
  bool disposed = false;
  bool fail = false;
  @override
  Stream<void> get completed => end.stream;
  @override
  Future<void> playAsset(String path, {bool loop = false}) async {
    if (disposed) throw StateError('disposed');
    if (fail) throw StateError('load failed');
    events.add('$path:$loop');
  }

  @override
  Future<void> stop() async {
    events.add('stop');
  }

  @override
  Future<void> dispose() async {
    disposed = true;
  }
}

class FakeSequencePlayer extends FakePlayer implements SequenceSoundPlayer {
  final finish = Completer<void>();
  @override
  Future<void> playAssets(List<String> paths) async {
    events.addAll(paths);
    await finish.future;
  }
}

void main() {
  test(
    'UI alternates players; loop has separate lifecycle and exact asset',
    () async {
      final players = <FakePlayer>[];
      final board = SoundBoard(
        playerFactory: () {
          final p = FakePlayer();
          players.add(p);
          return p;
        },
      );
      await board.play('card');
      await board.play('alert');
      expect(players[0].events, ['stop', 'sounds/card.mp3:false']);
      expect(players[1].events, ['stop', 'sounds/alert.mp3:false']);
      await board.loop('ambient');
      expect(players[2].events, ['stop', 'sounds/ambient.mp3:true']);
      await board.stopLoop();
      expect(players[2].events.last, 'stop');
      await board.play('unknown');
      expect(players.length, 3);
      await board.dispose();
      expect(players.every((p) => p.disposed), true);
      await board.play('card');
      expect(players[0].events.length, 2);
    },
  );
  test('native completion gates the next clip and whole presentation', () {
    fakeAsync((clock) {
      final players = <FakePlayer>[];
      final board = SoundBoard(
        playerFactory: () {
          final p = FakePlayer();
          players.add(p);
          return p;
        },
      );
      final order = <String>[];
      unawaited(
        board.present(() async {
          await board.playNow(['applause', 'card']);
          order.add('result');
          await board.playNow(['your_turn']);
        }),
      );
      unawaited(board.playSequence(['alert']));
      clock.flushMicrotasks();
      expect(players[3].events, ['sounds/applause.mp3:false']);
      clock.elapse(const Duration(seconds: 10));
      clock.flushMicrotasks();
      expect(players.length, 4); // elapsed estimates never mean completed
      players[3].end.add(null);
      clock.flushMicrotasks();
      expect(players[3].events.last, 'sounds/card.mp3:false');
      expect(order, isEmpty);
      players[3].end.add(null);
      clock.flushMicrotasks();
      expect(order, ['result']);
      expect(players[4].events, ['sounds/your_turn.mp3:false']);
      players[4].end.add(null);
      clock.flushMicrotasks();
      expect(players[5].events, ['sounds/alert.mp3:false']);
      players[5].end.add(null);
      clock.flushMicrotasks();
      unawaited(board.dispose());
      clock.flushMicrotasks();
      expect(players.every((p) => p.disposed), true);
    });
  });
  test('cancel during native completion unblocks and drops queued turns', () {
    fakeAsync((clock) {
      final players = <FakePlayer>[];
      final board = SoundBoard(
        playerFactory: () {
          final p = FakePlayer();
          players.add(p);
          return p;
        },
      );
      final completed = <String>[];
      unawaited(
        board.playSequence(['card']).catchError((Object e) {
          completed.add('cancelled');
        }),
      );
      unawaited(
        board.present(() async {
          completed.add('stale');
        }),
      );
      clock.flushMicrotasks();
      unawaited(board.cancelPresentations());
      clock.flushMicrotasks();
      expect(completed, ['cancelled']);
      expect(players[3].disposed, true);
      unawaited(
        board.present(() async {
          completed.add('fresh');
        }),
      );
      clock.flushMicrotasks();
      expect(completed, ['cancelled', 'fresh']);
      unawaited(board.dispose());
      clock.flushMicrotasks();
    });
  });
  test(
    'native sequence future gates result, propagates errors and cleans up',
    () {
      fakeAsync((clock) {
        final players = <FakeSequencePlayer>[];
        final board = SoundBoard(
          playerFactory: () {
            final player = FakeSequencePlayer();
            players.add(player);
            return player;
          },
        );
        final events = <String>[];
        unawaited(
          board
              .present(() async {
                await board.playNow(['card', 'your_turn']);
                events.add('result');
              })
              .catchError((Object e) {
                events.add('error');
              }),
        );
        clock.flushMicrotasks();
        expect(players[3].events, ['sounds/card.mp3', 'sounds/your_turn.mp3']);
        // Past the clip durations but inside the stall budget: still gated.
        clock.elapse(const Duration(seconds: 2));
        clock.flushMicrotasks();
        expect(events, isEmpty);
        expect(players[3].disposed, false);
        players[3].finish.completeError(StateError('native play failed'));
        clock.flushMicrotasks();
        expect(events, ['error']);
        expect(players[3].disposed, true);
        unawaited(
          board.present(() async {
            await board.playNow(['card']);
            events.add('fresh');
          }),
        );
        clock.flushMicrotasks();
        expect(events, ['error']);
        players[4].finish.complete();
        clock.flushMicrotasks();
        expect(events, ['error', 'fresh']);
        expect(players[4].disposed, true);
        unawaited(board.dispose());
        clock.flushMicrotasks();
      });
    },
  );
  test('native stall past the clip budget fails the presentation fast', () {
    fakeAsync((clock) {
      final players = <FakeSequencePlayer>[];
      final board = SoundBoard(
        playerFactory: () {
          final player = FakeSequencePlayer();
          players.add(player);
          return player;
        },
      );
      final events = <String>[];
      unawaited(
        board
            .present(() async {
              await board.playNow(['card', 'your_turn']);
              events.add('result');
            })
            .catchError((Object e) {
              events.add('error');
            }),
      );
      clock.flushMicrotasks();
      // card 418ms + your_turn 967ms + 4s grace = a hung native player must
      // fail the presentation instead of freezing the queue for minutes.
      clock.elapse(const Duration(seconds: 30));
      clock.flushMicrotasks();
      expect(events, ['error']);
      expect(players[3].disposed, true);
      unawaited(
        board.present(() async {
          await board.playNow(['card']);
          events.add('fresh');
        }),
      );
      clock.flushMicrotasks();
      players[4].finish.complete();
      clock.flushMicrotasks();
      expect(events, ['error', 'fresh']);
      unawaited(board.dispose());
      clock.flushMicrotasks();
    });
  });
  test('real native adapter awaits play future instead of launch only', () {
    final source = File('lib/services/sound_player.dart').readAsStringSync();
    final native = source.substring(source.indexOf('Future<void> playAssets'));
    expect(native, contains('await _player.play();'));
    expect(native, isNot(contains('unawaited(')));
  });
  test('failed load does not hang later presentations', () async {
    final players = <FakePlayer>[];
    final board = SoundBoard(
      playerFactory: () {
        final p = FakePlayer()..fail = true;
        players.add(p);
        return p;
      },
    );
    await expectLater(board.playSequence(['card']), throwsStateError);
    expect(players.last.disposed, true);
    await board.dispose();
  });
}
