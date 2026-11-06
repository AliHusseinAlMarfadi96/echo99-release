import 'package:echo99/game/jackaroo.dart';
import 'package:echo99/screens/table_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _wrap(Widget child) => MaterialApp(
  home: Scaffold(body: Center(child: child)),
);

void main() {
  group('Jackaroo start dialog: 4-player teams choice', () {
    testWidgets('teams vs individual radios render with semantics', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(
          buildGameSettingsDialogForTest(
            showMode: true,
            initialMode: jackarooStandard,
            initialTimer: 0,
            showTeams: true,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('لعب الفرق'), findsOneWidget);
      expect(find.text('اللعب الفردي'), findsOneWidget);
      expect(
        find.text('اثنان مقابل اثنين، الشريكان متقابلان'),
        findsOneWidget,
      );
      expect(find.text('كل لاعب لنفسه، ولا شريك لأحد'), findsOneWidget);

      // Both choices are exposed to the screen reader as radio buttons.
      final radios = tester
          .getSemantics(find.byType(RadioListTile<bool>).first)
          .getSemanticsData();
      expect(radios.flagsCollection.isInMutuallyExclusiveGroup, isTrue);

    });

testWidgets('timer field is enabled, editable, and holds its value', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(
          buildGameSettingsDialogForTest(
            showMode: true,
            initialMode: jackarooStandard,
            initialTimer: 30,
            showTeams: true,
          ),
        ),
      );
      await tester.pumpAndSettle();
      final field = tester.widget<TextField>(find.byType(TextField));
      expect(field.controller!.text, '30');
      expect(field.enabled, isNot(false));
      await tester.enterText(find.byType(TextField), '45');
      expect(field.controller!.text, '45');
      // The text-field flag merges onto the EditableText descendant node.
      final semantics = tester.getSemantics(
        find.descendant(
          of: find.byType(TextField),
          matching: find.byType(EditableText),
        ),
      );
      expect(semantics.getSemanticsData().flagsCollection.isTextField, isTrue);
    });

    testWidgets('hidden when the table is not 4-player jackaroo', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(
          buildGameSettingsDialogForTest(
            showMode: true,
            initialMode: jackarooStandard,
            initialTimer: 0,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('لعب الفرق'), findsNothing);
      expect(find.text('اللعب الفردي'), findsNothing);
    });

    testWidgets('picking individual returns teams=false', (tester) async {
      Object? result;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => FilledButton(
              onPressed: () async {
                result = await showDialog<Object>(
                  context: context,
                  builder: (_) => buildGameSettingsDialogForTest(
                    showMode: true,
                    initialMode: jackarooStandard,
                    initialTimer: 0,
                    showTeams: true,
                  ),
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('اللعب الفردي'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('تأكيد وبدء'));
      await tester.pumpAndSettle();
      expect(result, isNotNull);
      expect((result! as dynamic).teams, isFalse);
    });
  });
}
