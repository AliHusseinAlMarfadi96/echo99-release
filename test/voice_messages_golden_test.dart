import 'dart:io';

import 'package:echo99/services/voice_authority.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Pixel proof for the review-flagged moderation-failure snackbar: the
/// exact production strings from voiceActionFailureText rendered with a
/// real Arabic font (Noto Naskh Arabic), with the retry action visible.
void main() {
  testWidgets('voice moderation failure snackbar renders with retry action',
      (tester) async {
    final bytes = File('test/assets/NotoNaskhArabic.ttf').readAsBytesSync();
    final loader = FontLoader('NotoNaskh')
      ..addFont(Future.value(ByteData.view(bytes.buffer)));
    await loader.load();

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(fontFamily: 'NotoNaskh'),
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: ElevatedButton(
                onPressed: () {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(
                        voiceActionFailureText(
                          const VoiceModerationException('mute', 'u1'),
                          'الكتم',
                        ),
                      ),
                      action: SnackBarAction(
                        label: 'إعادة المحاولة',
                        onPressed: () {},
                      ),
                    ),
                  );
                },
                child: const Text('show'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('show'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(
      find.text('حُفظ الكتم، لكن تعذّر تطبيقه على المشارك المتصل الآن'),
      findsOneWidget,
    );
    expect(find.text('إعادة المحاولة'), findsOneWidget);
    await expectLater(
      find.byType(SnackBar),
      matchesGoldenFile('goldens/voice_moderation_failure_snackbar.png'),
    );
  });
}
