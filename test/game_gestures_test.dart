import 'package:echo99/widgets/game_gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('SwipeTracker', () {
    test('two fingers moving up = up, left = left', () {
      final t = SwipeTracker();
      t.down(1, const Offset(100, 400), 0);
      t.down(2, const Offset(160, 400), 5);
      t.move(1, const Offset(100, 300), 50);
      t.move(2, const Offset(160, 300), 50);
      expect(t.up(1, const Offset(100, 250), 120, screenReader: false), isNull);
      expect(
        t.up(2, const Offset(160, 250), 130, screenReader: false),
        GameSwipe.up,
      );
      t.down(1, const Offset(300, 400), 1000);
      t.down(2, const Offset(300, 460), 1000);
      t.move(1, const Offset(250, 400), 1040);
      t.up(1, const Offset(150, 400), 1100, screenReader: false);
      expect(
        t.up(2, const Offset(150, 460), 1100, screenReader: false),
        GameSwipe.left,
      );
    });

    test('one finger is ignored without a screen reader', () {
      final t = SwipeTracker();
      t.down(1, const Offset(100, 100), 0);
      t.move(1, const Offset(100, 200), 30);
      expect(t.up(1, const Offset(100, 300), 100, screenReader: false), isNull);
    });

    test('TalkBack pass-through: quick single pointer swipe counts', () {
      final t = SwipeTracker();
      t.down(1, const Offset(100, 100), 0);
      t.move(1, const Offset(100, 160), 40);
      expect(
        t.up(1, const Offset(100, 300), 150, screenReader: true),
        GameSwipe.down,
      );
    });

    test('a hold before dragging (double-tap-and-hold) is not a swipe', () {
      final t = SwipeTracker();
      t.down(1, const Offset(100, 100), 0);
      t.move(1, const Offset(100, 160), 600);
      expect(t.up(1, const Offset(100, 300), 800, screenReader: true), isNull);
    });

    test('cancelling one pointer resets the whole gesture and stale deltas', () {
      final t = SwipeTracker();
      t.down(1, const Offset(100, 100), 0);
      t.down(2, const Offset(160, 100), 5);
      t.move(1, const Offset(100, 40), 30);
      t.move(2, const Offset(160, 40), 30);
      t.cancel(1);

      // A pointer from the cancelled gesture must no longer complete it.
      expect(t.up(2, const Offset(160, 0), 80, screenReader: false), isNull);

      // A fresh one-finger gesture must not inherit the old two-finger count.
      t.down(3, const Offset(100, 100), 100);
      t.move(3, const Offset(100, 40), 130);
      expect(t.up(3, const Offset(100, 0), 180, screenReader: false), isNull);

      // A new two-finger gesture still works after the cancellation.
      t.down(4, const Offset(100, 200), 300);
      t.down(5, const Offset(160, 200), 305);
      t.move(4, const Offset(100, 130), 340);
      t.move(5, const Offset(160, 130), 340);
      expect(t.up(4, const Offset(100, 100), 390, screenReader: false), isNull);
      expect(
        t.up(5, const Offset(160, 100), 395, screenReader: false),
        GameSwipe.up,
      );
    });
  });

  group('GameGestureSurface semantics', () {
    Widget app(void Function(GameSwipe) onSwipe, VoidCallback onTap) {
      return MaterialApp(
        home: Scaffold(
          body: GameGestureSurface(
            onSwipe: onSwipe,
            actions: {
              const CustomSemanticsAction(label: 'إعلان الدور'): () =>
                  onSwipe(GameSwipe.up),
            },
            child: Column(
              children: [
                Expanded(
                  child: GameScrollBody(
                    child: Column(
                      children: [
                        for (var i = 0; i < 30; i++)
                          GameNode(
                            label: 'الأحمر قطعة ${i + 1}، الخانة 14، آمنة',
                            onTap: onTap,
                            child: const SizedBox(height: 60, width: 200),
                          ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    testWidgets(
      'every piece is its own node with label, tap and the table actions; '
      'scroll actions reach the surface, no scrollable in between',
      (tester) async {
        final handle = tester.ensureSemantics();
        final swipes = <GameSwipe>[];
        var taps = 0;
        await tester.pumpWidget(app(swipes.add, () => taps++));

        final piece = find.bySemanticsLabel('الأحمر قطعة 1، الخانة 14، آمنة');
        expect(piece, findsOneWidget);
        final node = tester.getSemantics(piece);
        final data = node.getSemanticsData();
        expect(data.hasAction(SemanticsAction.tap), isTrue);
        expect(data.flagsCollection.isButton, isTrue);
        expect(data.customSemanticsActionIds, isNotEmpty);

        // Walk up: the first ancestor with scroll actions must be the surface
        // that owns all four directions (VoiceOver bubbles accessibilityScroll).
        SemanticsNode? up = node.parent;
        SemanticsNode? surface;
        while (up != null) {
          final d = up.getSemanticsData();
          if (d.hasAction(SemanticsAction.scrollUp) ||
              d.hasAction(SemanticsAction.scrollDown)) {
            surface = up;
            break;
          }
          expect(d.flagsCollection.hasImplicitScrolling, isFalse);
          up = up.parent;
        }
        expect(surface, isNotNull);
        final sd = surface!.getSemanticsData();
        for (final a in [
          SemanticsAction.scrollUp,
          SemanticsAction.scrollDown,
          SemanticsAction.scrollLeft,
          SemanticsAction.scrollRight,
        ]) {
          expect(sd.hasAction(a), isTrue, reason: '$a');
        }

        final owner = node.owner!;
        // The surface debounces one physical gesture (raw + semantic) for
        // 400 ms of wall-clock time.
        Future<void> gap() => tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 450)),
        );
        owner.performAction(surface.id, SemanticsAction.scrollDown);
        await gap();
        owner.performAction(surface.id, SemanticsAction.scrollLeft);
        await gap();
        owner.performAction(surface.id, SemanticsAction.scrollUp);
        await gap();
        owner.performAction(surface.id, SemanticsAction.scrollRight);
        expect(swipes, [
          GameSwipe.down,
          GameSwipe.left,
          GameSwipe.up,
          GameSwipe.right,
        ]);

        owner.performAction(node.id, SemanticsAction.tap);
        expect(taps, 1);
        handle.dispose();
      },
    );

    testWidgets('rapid semantic swipes are not dropped', (tester) async {
      final handle = tester.ensureSemantics();
      final swipes = <GameSwipe>[];
      await tester.pumpWidget(app(swipes.add, () {}));

      final piece = tester.getSemantics(
        find.bySemanticsLabel('الأحمر قطعة 1، الخانة 14، آمنة'),
      );
      SemanticsNode? ancestor = piece.parent;
      SemanticsNode? surface;
      while (ancestor != null) {
        final data = ancestor.getSemanticsData();
        if (data.hasAction(SemanticsAction.scrollDown)) {
          surface = ancestor;
          break;
        }
        ancestor = ancestor.parent;
      }
      expect(surface, isNotNull);
      final owner = piece.owner!;
      owner.performAction(surface!.id, SemanticsAction.scrollDown);
      owner.performAction(surface.id, SemanticsAction.scrollDown);

      expect(swipes, [GameSwipe.down, GameSwipe.down]);
      handle.dispose();
    });

    testWidgets('a raw two-finger swipe fires once', (tester) async {
      final swipes = <GameSwipe>[];
      await tester.pumpWidget(app(swipes.add, () {}));
      final a = await tester.startGesture(const Offset(200, 400), pointer: 1);
      final b = await tester.startGesture(const Offset(260, 400), pointer: 2);
      await a.moveBy(const Offset(0, -60));
      await b.moveBy(const Offset(0, -60));
      await a.moveBy(const Offset(0, -60));
      await b.moveBy(const Offset(0, -60));
      await a.up();
      await b.up();
      await tester.pump();
      expect(swipes, [GameSwipe.up]);
    });
  });
}
