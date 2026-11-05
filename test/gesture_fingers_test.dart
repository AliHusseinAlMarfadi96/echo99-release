import 'package:echo99/widgets/mic_gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('MicGestures builds without stealing child semantics', (
    tester,
  ) async {
    var toggled = false;
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.rtl,
        child: MicGestures(
          onMicOn: () {},
          onMicOff: () {},
          onToggle: () => toggled = true,
          child: const Text('طاولة'),
        ),
      ),
    );
    expect(find.text('طاولة'), findsOneWidget);
    // Long-press toggles mic (accessible alternative to vertical swipe).
    await tester.longPress(find.text('طاولة'));
    expect(toggled, isTrue);
  });
}
