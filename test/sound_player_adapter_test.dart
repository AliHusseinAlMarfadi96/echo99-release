import 'dart:async';

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
  test(
    'long sequence queue never resets into overlap; completion disposes layer',
    () {
      fakeAsync((clock) {
        final players = <FakePlayer>[];
        final board = SoundBoard(
          nowMillis: () => clock.elapsed.inMilliseconds,
          playerFactory: () {
            final p = FakePlayer();
            players.add(p);
            return p;
          },
        );
        unawaited(board.playSequence(['applause', 'card']));
        unawaited(board.playSequence(['alert']));
        clock.flushMicrotasks();
        expect(players.length, 4);
        expect(players[3].events, ['sounds/applause.mp3:false']);
        clock.elapse(const Duration(seconds: 6));
        clock.flushMicrotasks();
        expect(players.length, 4); // Do not start card/alert over applause.
        clock.elapse(const Duration(milliseconds: 400));
        clock.flushMicrotasks();
        expect(players[4].events, ['sounds/card.mp3:false']);
        players[3].end.add(null);
        clock.flushMicrotasks();
        expect(players[3].disposed, true);
        clock.elapse(const Duration(seconds: 2));
        clock.flushMicrotasks();
        expect(players[5].events, ['sounds/alert.mp3:false']);
        unawaited(board.dispose());
        clock.flushMicrotasks();
        expect(players.every((p) => p.disposed), true);
      });
    },
  );
  test(
    'failed layer load disposes; pending sequence does not fire after dispose',
    () {
      fakeAsync((clock) {
        final players = <FakePlayer>[];
        final board = SoundBoard(
          nowMillis: () => clock.elapsed.inMilliseconds,
          playerFactory: () {
            final p = FakePlayer()..fail = players.length >= 3;
            players.add(p);
            return p;
          },
        );
        unawaited(board.playSequence(['card', 'alert']));
        clock.flushMicrotasks();
        expect(players[3].disposed, true);
        unawaited(board.dispose());
        clock.flushMicrotasks();
        clock.elapse(const Duration(seconds: 3));
        clock.flushMicrotasks();
        expect(players.length, 4);
      });
    },
  );
}
