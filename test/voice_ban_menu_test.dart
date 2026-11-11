import 'dart:async';
import 'dart:io';

import 'package:echo99/echo_scope.dart';
import 'package:echo99/game/engine.dart';
import 'package:echo99/game/jackaroo.dart';
import 'package:echo99/screens/table_screen.dart';
import 'package:echo99/services/account.dart';
import 'package:echo99/services/presence.dart';
import 'package:echo99/services/settings_model.dart';
import 'package:echo99/services/sound_player.dart';
import 'package:echo99/services/sounds.dart';
import 'package:echo99/services/speech.dart';
import 'package:echo99/services/table_repository.dart';
import 'package:echo99/services/voice_room.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class _SilentPlayer implements SoundPlayer {
  @override
  Stream<void> get completed => const Stream.empty();
  @override
  Future<void> playAsset(String path, {bool loop = false}) async {}
  @override
  Future<void> stop() async {}
  @override
  Future<void> dispose() async {}
}

class _FakeRepo implements TableRepository {
  _FakeRepo(this.state);
  final MatchState state;
  final updates = StreamController<MatchState?>.broadcast();
  @override
  Stream<MatchState?> watchTable(String id) async* {
    yield state;
    yield* updates.stream;
  }

  @override
  Stream<List<TableLogEntry>> watchLog(String id) => const Stream.empty();
  @override
  Future<void> rename({
    required String tableId,
    required String playerId,
    required String playerName,
  }) async {}
  @override
  Future<void> heartbeat(String tableId) async {}
  @override
  Future<void> deleteTableCompletely(String tableId) async {}
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class _FakePresence extends PresenceService {
  @override
  Future<void> joinTable({required String tableId, required bool host}) async {}
  @override
  Future<void> leaveTable() async {}
  @override
  Stream<Set<String>> watchSeats(String id) => const Stream.empty();
}

class _FakeVoice extends VoiceRoom {
  @override
  Future<String?> joinAsListener({
    required String identity,
    required String displayName,
    required String tableId,
    bool autoEnableMic = false,
  }) async => null;
}

void main() {
  testWidgets('host seat menu shows the voice-only ban item', (tester) async {
    final arabic = FontLoader('ReviewArabic')
      ..addFont(
        Future.value(
          ByteData.sublistView(
            File('test/assets/NotoNaskhArabic.ttf').readAsBytesSync(),
          ),
        ),
      );
    await arabic.load();

    tester.view.physicalSize = const Size(432, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final settings = SettingsModel(
      playerId: 'a',
      name: 'علي',
      speakPlays: false,
      useInternalTts: false,
      nameCards: true,
      botMillis: 1500,
    );
    final base = newWaitingTable(
      id: 't1',
      name: 'طاولة',
      hostId: 'a',
      hostName: 'علي',
      settings: const TableSettings(startPoints: 10, timerSeconds: 0),
      game: gameJackaroo,
    );
    final map = base.toMap();
    map['players'] = [
      {
        'id': 'a',
        'name': 'علي',
        'points': 10,
        'isBot': false,
        'micMuted': false,
        'chatBlocked': false,
      },
      {
        'id': 'b',
        'name': 'خالد',
        'points': 10,
        'isBot': false,
        'micMuted': false,
        'chatBlocked': false,
      },
    ];
    map['status'] = 'playing';
    map['hands'] = {
      'a': ['S9', 'C1', 'C7', 'H4'],
    };
    map['board'] = {
      'mode': jackarooStandard,
      'colors': {'a': 0, 'b': 2},
      'pieces': {
        'a': [0, 10, -99, -99],
        'b': [-99, -99, -99, -99],
      },
    };
    final state = MatchState.fromMap(map, 't1');

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark().copyWith(
          textTheme: ThemeData.dark().textTheme.apply(
            fontFamily: 'ReviewArabic',
          ),
        ),
        home: EchoScope(
          settings: settings,
          account: AccountController(settings),
          repo: _FakeRepo(state),
          social: null,
          sounds: SoundBoard(playerFactory: _SilentPlayer.new),
          speech: Speech(),
          voice: _FakeVoice(),
          presence: _FakePresence(),
          child: Directionality(
            textDirection: TextDirection.rtl,
            child: TableScreen(tableId: 't1', initial: state),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    // Host taps the other player's name to open the seat action sheet.
    await tester.tap(find.text('خالد'), warnIfMissed: false);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('منع من المحادثة الصوتية'), findsOneWidget);
    expect(find.text('كتم الميكروفون'), findsOneWidget);
    expect(find.text('طرد'), findsOneWidget);
    final semantics = tester.ensureSemantics();
    expect(
      tester.getSemantics(find.text('منع من المحادثة الصوتية')),
      isNotNull,
    );
    await expectLater(
      find.byType(BottomSheet),
      matchesGoldenFile('goldens/voice_ban_menu.png'),
    );
    semantics.dispose();
  });
}
