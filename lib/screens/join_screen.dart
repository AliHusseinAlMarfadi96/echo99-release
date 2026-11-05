import 'package:flutter/material.dart';

import '../echo_scope.dart';
import '../game/engine.dart';
import '../services/table_repository.dart';
import 'table_screen.dart';

class JoinScreen extends StatelessWidget {
  const JoinScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final repo = EchoScope.of(context).repo;
    return Scaffold(
      appBar: AppBar(title: const Text('الانضمام إلى طاولة')),
      body: repo == null
          ? const Center(child: Text('تعذر الاتصال بـ Firestore'))
          : StreamBuilder<List<TableSummary>>(
              stream: repo.watchTables(),
              builder: (context, snapshot) {
                if (snapshot.hasError) {
                  return const Center(child: Text('تعذر الاتصال بـ Firestore'));
                }
                if (!snapshot.hasData) {
                  return const Center(child: CircularProgressIndicator());
                }
                return TableListView(
                  tables: snapshot.data!,
                  onOpen: (table) => _open(context, table.id),
                );
              },
            ),
    );
  }

  Future<void> _open(BuildContext context, String id) async {
    final scope = EchoScope.of(context);
    final repo = scope.repo;
    if (repo == null) {
      return;
    }
    final result = await repo.join(
      tableId: id,
      playerId: scope.settings.playerId,
      playerName: scope.settings.displayName,
    );
    if (!context.mounted) {
      return;
    }
    if (result != null && result != 'watch') {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(result)));
      return;
    }
    if (!context.mounted) {
      return;
    }
    await Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => TableScreen(tableId: id)));
  }
}

class TableListView extends StatelessWidget {
  const TableListView({super.key, required this.tables, required this.onOpen});

  final List<TableSummary> tables;
  final ValueChanged<TableSummary> onOpen;

  @override
  Widget build(BuildContext context) {
    if (tables.isEmpty) {
      return const Center(child: Text('لا توجد طاولة'));
    }
    return ListView.separated(
      itemCount: tables.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final table = tables[index];
        final status = switch (table.status) {
          'playing' => 'جارية',
          'finished' => 'انتهت',
          _ => 'انتظار',
        };
        return ListTile(
          title: Text(table.name),
          subtitle: Text(
            '${gameLabel(table.game)} · ${table.playerCount} · $status',
          ),
          onTap: () => onOpen(table),
        );
      },
    );
  }
}
