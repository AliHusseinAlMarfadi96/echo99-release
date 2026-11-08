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
  Future<void> playAsset(String path, {bool loop = false, double? speed}) async {}
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
  Future<String?> leave({required String tableId, required String playerId}) async => null;
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

/// A voice service whose "connected" LiveKit room exposes a controllable
/// authoritative roster, like the real remoteParticipants feed.
class _RosterVoice extends VoiceRoom {
  final roster = StreamController<List<String>>.broadcast();
  @override
  bool get connected => true;
  @override
  Stream<List<String>> get remoteRoster => roster.stream;
  @override
  Future<String?> joinAsListener({
    required String identity,
    required String displayName,
    required String tableId,
    bool autoEnableMic = false,
  }) async => null;
}

MatchState _state() {
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
  return MatchState.fromMap(map, 't1');
}

Future<_RosterVoice> _pump(
  WidgetTester tester, {
  required String playerId,
  required String playerName,
}) async {
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
    playerId: playerId,
    name: playerName,
    speakPlays: false,
    useInternalTts: false,
    nameCards: true,
    botMillis: 1500,
  );
  final state = _state();
  final voice = _RosterVoice();
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData.dark().copyWith(
        textTheme: ThemeData.dark().textTheme.apply(fontFamily: 'ReviewArabic'),
      ),
      home: EchoScope(
        settings: settings,
        account: AccountController(settings),
        repo: _FakeRepo(state),
        social: null,
        sounds: SoundBoard(playerFactory: _SilentPlayer.new),
        speech: Speech(),
        voice: voice,
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
  return voice;
}

void main() {
  testWidgets(
    'participants row comes from the live roster: seated names plus '
    'non-seated observers, and the host can voice-ban an observer',
    (tester) async {
      final voice = await _pump(tester, playerId: 'a', playerName: 'علي');
      voice.roster.add(const ['b', 'obs12345']);
      await tester.pump();
      await tester.pump();

      // Seated participant resolves to the seat name; the non-seated
      // observer is labelled as a voice participant, not hidden.
      expect(find.text('خالد'), findsWidgets);
      expect(find.text('مشارك صوتي obs1'), findsOneWidget);
      await expectLater(
        find.byType(TableScreen),
        matchesGoldenFile('goldens/voice_participants_roster.png'),
      );

      // Host taps the observer: voice-only moderation (no seat controls).
      await tester.tap(find.text('مشارك صوتي obs1'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('منع من المحادثة الصوتية'), findsOneWidget);
      expect(find.text('كتم الميكروفون'), findsOneWidget);
      expect(find.text('طرد'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('non-host gets no moderation sheet for an observer', (
    tester,
  ) async {
    final voice = await _pump(tester, playerId: 'b', playerName: 'خالد');
    voice.roster.add(const ['obs12345']);
    await tester.pump();
    await tester.pump();
    expect(find.text('مشارك صوتي obs1'), findsOneWidget);
    await tester.tap(find.text('مشارك صوتي obs1'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('منع من المحادثة الصوتية'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('roster failure shows a clearly labelled fallback', (
    tester,
  ) async {
    final voice = await _pump(tester, playerId: 'a', playerName: 'علي');
    voice.roster.addError(StateError('roster unavailable'));
    await tester.pump();
    await tester.pump();
    expect(
      find.text('تعذّر تحديث قائمة المشاركين في الصوت؛ المعروض قد لا يكون كاملاً'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });
}
