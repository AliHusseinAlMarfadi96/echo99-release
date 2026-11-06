// Move-chooser option rendering: real generated labels at phone width and
// 1.3x text scale must lay out without overflow and expose semantics.
import 'dart:math';

import 'package:echo99/game/engine.dart';
import 'package:echo99/game/jackaroo.dart';
import 'package:echo99/game/lifecycle.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('jackaroo move chooser options', () {
    MatchState sample() {
      var state = newWaitingTable(
        id: 't',
        name: 'طاولة',
        hostId: 'A',
        hostName: 'A',
        settings: const TableSettings(startPoints: 10, timerSeconds: 0),
        game: gameJackaroo,
      );
      state = addBot(state, 'B', 'B').state;
      state = applyJackarooMode(state, jackarooStandard, 0).state;
      state = startGame(state, Random(2), 0).state;
      return MatchState.fromMap({
        ...state.toMap(),
        'turnIndex': 0,
        'hands': {
          'A': ['S2', 'S11', 'S7'],
          'B': ['H2'],
        },
        'board': {
          'mode': jackarooStandard,
          'colors': {'A': 0, 'B': 1},
          'pieces': {
            'A': [10, 20, jackarooHome, jackarooHome],
            'B': [72, 62, jackarooHome, jackarooHome],
          },
          'sixChain': 0,
        },
      }, 't');
    }

    testWidgets('long context labels lay out at phone width, 1.3x scale', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(360 * 2, 700 * 2);
      tester.view.devicePixelRatio = 2;
      addTearDown(tester.view.reset);
      final tapped = <String>[];
      final s = sample();
      final labels = <String>[
        for (final card in ['S2', 'S11', 'S7'])
          for (final m in jackarooMovesForCard(s, 'A', card))
            jackarooMoveLabel(s, m),
      ];
      expect(labels, isNotEmpty);
      expect(labels.any((l) => l.contains('يصبح أمامك')), isTrue);
      await tester.pumpWidget(
        MaterialApp(
          home: Directionality(
            textDirection: TextDirection.rtl,
            child: MediaQuery(
              data: const MediaQueryData(
                textScaler: TextScaler.linear(1.3),
              ),
              child: SimpleDialog(
                title: const Text('اختر القطعة'),
                children: [
                  for (final l in labels)
                    SimpleDialogOption(
                      onPressed: () => tapped.add(l),
                      child: Text(l),
                    ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      // RenderFlex/text overflow throws inside the widget tree.
      expect(tester.takeException(), isNull);
      for (final l in labels) {
        expect(find.text(l), findsOneWidget);
      }
      // Every option is present and tappable (behavioral proof over flags).
      expect(find.byType(SimpleDialogOption).evaluate().length, labels.length);
      for (final l in labels) {
        await tester.scrollUntilVisible(
          find.text(l),
          60,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.tap(find.text(l));
        await tester.pump();
      }
      expect(tapped, labels);
    });
  });
}
