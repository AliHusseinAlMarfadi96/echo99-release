import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:echo99/echo_scope.dart';
import 'package:echo99/game/engine.dart';
import 'package:echo99/game/jackaroo.dart';
import 'package:echo99/screens/table_screen.dart';
import 'package:echo99/services/account.dart';
import 'package:echo99/services/presence.dart';
import 'package:echo99/services/settings_model.dart';
import 'package:echo99/services/table_repository.dart';
import 'package:echo99/widgets/mic_pad.dart';
import 'package:echo99/services/sound_player.dart';
import 'package:echo99/services/sounds.dart';
import 'package:echo99/services/speech.dart';
import 'package:echo99/services/voice_room.dart';
import 'package:echo99/widgets/playing_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class SilentPlayer implements SoundPlayer {
  @override
  Stream<void> get completed => const Stream.empty();
  @override
  Future<void> playAsset(String path, {bool loop = false}) async {}
  @override
  Future<void> stop() async {}
  @override
  Future<void> dispose() async {}
}

class FakeRepo implements TableRepository {
  FakeRepo(this.state);
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

class FakePresence extends PresenceService {
  @override
  Future<void> joinTable({required String tableId, required bool host}) async {}
  @override
  Future<void> leaveTable() async {}
  @override
  Stream<Set<String>> watchSeats(String id) => const Stream.empty();
}

class FakeVoice extends VoiceRoom {
  @override
  Future<String?> joinAsListener({
    required String identity,
    required String displayName,
    required String tableId,
    bool autoEnableMic = false,
  }) async => null;
}

void main() {
  for (final online in [false, true]) {
    testWidgets('actual compact table cards and mic order online=$online', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      final render = Platform.environment['ECHO_REVIEW_RENDER'] == '1';
      if (render) {
        final font = FontLoader('ReviewArabic');
        font.addFont(
          Future.value(
            ByteData.sublistView(
              File(
                '/usr/share/fonts/truetype/noto/NotoSansArabicUI-Regular.ttf',
              ).readAsBytesSync(),
            ),
          ),
        );
        await font.load();
        final latin = FontLoader('ReviewLatin');
        latin.addFont(
          Future.value(
            ByteData.sublistView(
              File('/usr/share/fonts/truetype/noto/NotoSans-Regular.ttf')
                  .readAsBytesSync(),
            ),
          ),
        );
        await latin.load();
      }
      tester.view.physicalSize = const Size(432, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final settings = SettingsModel(
        playerId: 'a',
        name: 'علي',
        speakPlays: true,
        useInternalTts: false,
        nameCards: true,
        botMillis: 1500,
      );
      final sounds = SoundBoard(playerFactory: SilentPlayer.new);
      final presence = FakePresence();
      final s = newWaitingTable(
        id: 'localmatch',
        name: 'طاولة',
        hostId: 'a',
        hostName: 'علي',
        settings: const TableSettings(startPoints: 10, timerSeconds: 0),
        game: gameJackaroo,
      );
      final state = MatchState.fromMap({
        ...s.toMap(),
        'status': 'playing',
        'hands': {
          'a': ['S9', 'C1', 'C7', 'H4'],
        },
        'board': {
          'mode': jackarooStandard,
          'colors': {'a': 0, 'b': 2},
          'pieces': {
            'a': [0, 10, -99, -99],
            'b': [-99, -99, -99, -99],
          },
        },
      }, 'localmatch');
      final repo = FakeRepo(state);
      final boundary = GlobalKey();
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark().copyWith(
            scaffoldBackgroundColor: const Color(0xFF102019),
            textTheme: ThemeData.dark().textTheme.apply(
              fontFamily: 'ReviewArabic',
              fontFamilyFallback: ['ReviewLatin'],
            ),
          ),
          home: EchoScope(
            settings: settings,
            account: AccountController(settings),
            repo: online ? repo : null,
            social: null,
            sounds: sounds,
            speech: Speech(),
            voice: FakeVoice(),
            presence: presence,
            child: RepaintBoundary(
              key: boundary,
              child: Directionality(
                textDirection: TextDirection.rtl,
                child: TableScreen(
                  tableId: 'localmatch',
                  offline: !online,
                  initial: state,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      if (online) {
        expect(find.byType(MicPad), findsOneWidget);
        expect(
          tester.getRect(find.byType(MicPad)).top,
          greaterThanOrEqualTo(
            tester.getRect(find.byType(PlayingCardFace).last).bottom,
          ),
        );
      }
      expect(find.byType(PlayingCardFace), findsNWidgets(4));
      expect(find.textContaining('ثلاثة أصابع'), findsNothing);
      expect(find.textContaining('الأحمر قطعة'), findsNothing);
      expect(
        tester.getRect(find.byType(PlayingCardFace).first).bottom,
        lessThan(900),
      );
      expect(tester.takeException(), isNull);
      final cardElement = find
          .byKey(const ValueKey('hand-S9'))
          .evaluate()
          .single;
      await tester.pump(const Duration(seconds: 2));
      expect(
        find.byKey(const ValueKey('hand-S9')).evaluate().single,
        same(cardElement),
      );
      if (online) {
        final labels = <String>[];
        void walk(SemanticsNode node) {
          if (node.label.isNotEmpty) labels.add(node.label);
          for (final child in node.debugListChildrenInOrder(
            DebugSemanticsDumpOrder.traversalOrder,
          )) {
            walk(child);
          }
        }

        walk(
          tester
              .binding
              .renderViews
              .first
              .owner!
              .semanticsOwner!
              .rootSemanticsNode!,
        );
        final micIndex = labels.indexWhere(
          (s) => s.contains('الميكروفون مغلق'),
        );
        expect(micIndex, greaterThan(0));
        for (final face in tester.widgetList<PlayingCardFace>(
          find.byType(PlayingCardFace),
        )) {
          final index = labels.indexOf(face.card.englishName);
          expect(index, greaterThanOrEqualTo(0));
          expect(index, lessThan(micIndex));
        }
        repo.updates.add(
          MatchState.fromMap({
            ...state.toMap(),
            'hands': {
              'a': ['C1', 'S9', 'H4', 'D2'],
            },
          }, 'localmatch'),
        );
        await tester.pump();
        await tester.pump();
        expect(
          find.byKey(const ValueKey('hand-S9')).evaluate().single,
          same(cardElement),
        );
        expect(find.byKey(const ValueKey('hand-C7')), findsNothing);
        expect(find.byKey(const ValueKey('hand-D2')), findsOneWidget);
        final aceElement = find
            .byKey(const ValueKey('hand-C1'))
            .evaluate()
            .single;
        await tester.tap(find.byKey(const ValueKey('hand-C1')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.byType(SimpleDialog), findsOneWidget);
        expect(find.text('إلغاء'), findsOneWidget);
        await tester.tap(find.text('إلغاء'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.byType(SimpleDialog), findsNothing);
        expect(
          find.byKey(const ValueKey('hand-C1')).evaluate().single,
          same(aceElement),
        );
        expect(
          tester
              .getSemantics(find.byKey(const ValueKey('hand-C1')))
              .getSemanticsData()
              .hasAction(ui.SemanticsAction.tap),
          isTrue,
        );
      }
      if (render) {
        await tester.runAsync(() async {
          final image =
              await (boundary.currentContext!.findRenderObject()
                      as RenderRepaintBoundary)
                  .toImage();
          final data = await image.toByteData(format: ui.ImageByteFormat.png);
          await File(
            '/tmp/review0351/compact20-${online ? 'online' : 'offline'}.png',
          ).writeAsBytes(data!.buffer.asUint8List());
        });
      }
      await tester.pumpWidget(const SizedBox());
      semantics.dispose();
      await sounds.dispose();
      await repo.updates.close();
    });
  }
}
