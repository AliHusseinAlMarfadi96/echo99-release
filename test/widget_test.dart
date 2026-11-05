import 'package:echo99/screens/join_screen.dart';
import 'package:echo99/services/table_repository.dart';
import 'package:echo99/screens/menu_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('menu shows tables, settings, people, friends, and latency', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: MenuScreen(
          onCreate: () {},
          onJoin: () {},
          onSettings: () {},
          onOnline: () {},
          onFriends: () {},
          onLatency: () {},
          latencyLabel: 'زمن الاستجابة',
        ),
      ),
    );
    expect(find.widgetWithText(FilledButton, 'إنشاء طاولة'), findsOneWidget);
    expect(
      find.widgetWithText(FilledButton, 'الانضمام إلى طاولة'),
      findsOneWidget,
    );
    expect(find.widgetWithText(FilledButton, 'الإعدادات'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'المتصلون'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'الأصدقاء'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'زمن الاستجابة'), findsOneWidget);
    expect(find.byType(FilledButton), findsNWidgets(6));
  });

  testWidgets('empty table list shows the exact empty sentence', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: TableListView(tables: [], onOpen: _noop),
        ),
      ),
    );
    expect(find.text('لا توجد طاولة'), findsOneWidget);
  });
}

void _noop(TableSummary table) {}
