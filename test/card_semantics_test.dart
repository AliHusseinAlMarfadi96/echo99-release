import 'package:echo99/game/rules.dart';
import 'package:echo99/widgets/mic_pad.dart';
import 'package:echo99/widgets/playing_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('card: one semantics node (image + English text), tap plays', (
    tester,
  ) async {
    var played = 0;
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: PlayingCardFace(
              card: const PlayingCard('H', 12),
              onPlay: () => played++,
            ),
          ),
        ),
      ),
    );
    expect(find.text('Queen of Hearts'), findsOneWidget);
    expect(find.bySemanticsLabel('Queen of Hearts'), findsOneWidget);
    await tester.tap(find.byType(PlayingCardFace));
    expect(played, 1);
    // A swipe must not play.
    await tester.drag(find.byType(PlayingCardFace), const Offset(0, -200));
    await tester.pump();
    expect(played, 1);
    handle.dispose();
  });

  testWidgets('mic gestures live only on the mic pad', (tester) async {
    var toggles = 0;
    var on = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              const SizedBox(height: 200, child: Text('table')),
              MicPad(
                micOn: false,
                onMicOn: () => on++,
                onMicOff: () {},
                onToggle: () => toggles++,
              ),
            ],
          ),
        ),
      ),
    );
    await tester.longPress(find.text('table'));
    expect(toggles, 0);
    await tester.tap(find.byKey(const Key('mic_pad')));
    expect(toggles, 1);
    await tester.drag(find.byKey(const Key('mic_pad')), const Offset(0, -120));
    await tester.pump();
    expect(on, 1);
  });
}
