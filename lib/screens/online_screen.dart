import 'package:flutter/material.dart';

import '../echo_scope.dart';
import '../widgets/ar_button.dart';
import '../widgets/profile_dialog.dart';
import '../services/doc_id.dart';
import '../services/presence.dart';
import '../services/social_repository.dart';
import '../services/table_repository.dart';
import 'table_screen.dart';

class OnlineScreen extends StatelessWidget {
  const OnlineScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final scope = EchoScope.of(context);
    final social = scope.social;
    final uid = scope.settings.playerId;
    if (social == null || !isSafeDocId(uid)) {
      return Scaffold(
        appBar: AppBar(title: const Text('اللاعبون المتصلون')),
        body: const Center(child: Text('تعذر الاتصال بـ Firestore')),
      );
    }
    return Scaffold(
      appBar: AppBar(title: const Text('اللاعبون المتصلون')),
      body: Column(
        children: [
          StreamBuilder<List<TableInvite>>(
            stream: social.watchInvites(uid),
            builder: (context, snapshot) {
              final invites = snapshot.data ?? const <TableInvite>[];
              if (invites.isEmpty) {
                return const SizedBox.shrink();
              }
              return Column(
                children: [
                  for (final invite in invites)
                    ListTile(
                      title: Text('دعوة من ${invite.fromName}'),
                      trailing: ArTextButton(
                        label: 'انضمام',
                        onPressed: () => _join(context, invite.tableId),
                      ),
                    ),
                ],
              );
            },
          ),
          Expanded(
            child: StreamBuilder<List<OnlinePlayer>>(
              stream: onlinePlayers(
                presence: scope.presence,
                firestore: social.watchOnline,
              ),
              builder: (context, snapshot) {
                if (snapshot.hasError) {
                  return const Center(child: Text('تعذر الاتصال بـ Firestore'));
                }
                if (!snapshot.hasData) {
                  return const Center(child: CircularProgressIndicator());
                }
                final people = [
                  for (final player in snapshot.data!)
                    if (player.uid != uid) player,
                ];
                if (people.isEmpty) {
                  return const Center(child: Text('لا يوجد لاعب متصل'));
                }
                return ListView.separated(
                  itemCount: people.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (context, index) {
                    final player = people[index];
                    return ListTile(
                      title: Text(player.name),
                      onTap: () => showProfileDialog(
                        context,
                        uid: player.uid,
                        name: player.name,
                      ),
                      trailing: Wrap(
                        spacing: 8,
                        children: [
                          ArTextButton(
                            label: 'متابعة',
                            onPressed: () => social.follow(
                              uid: uid,
                              friendUid: player.uid,
                              name: player.name,
                            ),
                          ),
                          ArTextButton(
                            label: 'دعوة',
                            onPressed: () => _invite(context, player),
                          ),
                          ArTextButton(
                            label: 'رسالة',
                            onPressed: () => _message(context, player),
                          ),
                        ],
                      ),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _invite(BuildContext context, OnlinePlayer player) async {
    final scope = EchoScope.of(context);
    final repo = scope.repo;
    final social = scope.social;
    if (repo == null || social == null) {
      return;
    }
    final tableId = await showDialog<String>(
      context: context,
      builder: (context) =>
          _InviteDialog(repo: repo, hostId: scope.settings.playerId),
    );
    if (tableId == null || !context.mounted) {
      return;
    }
    if (!isSafeDocId(tableId)) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('معرّف الطاولة غير صالح.')));
      return;
    }
    try {
      await social.invite(
        fromUid: scope.settings.playerId,
        toUid: player.uid,
        fromName: scope.settings.displayName,
        tableId: tableId,
      );
      scope.sounds.play('invite');
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('تعذر إرسال الدعوة.')));
      }
    }
  }

  Future<void> _message(BuildContext context, OnlinePlayer player) async {
    final text = await showDialog<String>(
      context: context,
      builder: (context) => const _MessageDialog(),
    );
    if (text == null || text.trim().isEmpty || !context.mounted) {
      return;
    }
    final scope = EchoScope.of(context);
    final social = scope.social;
    if (social == null) {
      return;
    }
    try {
      await social.sendPrivateMessage(
        fromUid: scope.settings.playerId,
        toUid: player.uid,
        fromName: scope.settings.displayName,
        text: text,
      );
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('تعذر إرسال الرسالة.')));
      }
    }
  }

  Future<void> _join(BuildContext context, String tableId) async {
    final scope = EchoScope.of(context);
    final repo = scope.repo;
    if (repo == null || !isSafeDocId(tableId)) {
      return;
    }
    final result = await repo.join(
      tableId: tableId,
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
    await Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => TableScreen(tableId: tableId)));
  }
}

class _InviteDialog extends StatefulWidget {
  const _InviteDialog({required this.repo, required this.hostId});

  final TableRepository repo;
  final String hostId;

  @override
  State<_InviteDialog> createState() => _InviteDialogState();
}

class _InviteDialogState extends State<_InviteDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('دعوة إلى طاولة'),
      content: SizedBox(
        width: 320,
        child: StreamBuilder<List<TableSummary>>(
          stream: widget.repo.watchTables(),
          builder: (context, snapshot) {
            final mine = [
              for (final table in snapshot.data ?? const <TableSummary>[])
                if (table.hostId == widget.hostId && isSafeDocId(table.id))
                  table,
            ];
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final table in mine)
                  ListTile(
                    title: Text(table.name),
                    onTap: () => Navigator.of(context).pop(table.id),
                  ),
                TextField(
                  controller: _controller,
                  decoration: const InputDecoration(labelText: 'معرّف الطاولة'),
                ),
              ],
            );
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('إلغاء'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(_controller.text.trim()),
          child: const Text('دعوة'),
        ),
      ],
    );
  }
}

class _MessageDialog extends StatefulWidget {
  const _MessageDialog();

  @override
  State<_MessageDialog> createState() => _MessageDialogState();
}

class _MessageDialogState extends State<_MessageDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('رسالة خاصة', textDirection: TextDirection.rtl),
      content: TextField(
        controller: _controller,
        textDirection: TextDirection.rtl,
        decoration: const InputDecoration(labelText: 'النص'),
      ),
      actions: [
        ArTextButton(
          label: 'إلغاء',
          onPressed: () => Navigator.of(context).pop(),
        ),
        ArTextButton(
          label: 'إرسال',
          onPressed: () => Navigator.of(context).pop(_controller.text.trim()),
        ),
      ],
    );
  }
}
