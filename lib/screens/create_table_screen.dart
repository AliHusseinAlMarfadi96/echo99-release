import 'dart:async';
import 'package:firebase_auth/firebase_auth.dart';

import 'package:flutter/material.dart';

import '../echo_scope.dart';
import '../game/engine.dart';
import '../game/rules.dart';
import '../services/local_match.dart';
import '../widgets/ar_button.dart';
import 'table_screen.dart';

/// Host picks the game; the table is created instantly with the host's name.
/// No settings here — max points / timer / mode appear only when the host
/// taps «بدء».
class CreateTableScreen extends StatefulWidget {
  const CreateTableScreen({super.key, this.offline = false});

  /// Offline tables stay on this device and play against added bots only.
  final bool offline;

  @override
  State<CreateTableScreen> createState() => _CreateTableScreenState();
}

/// Default table name: «طاولة» followed by the host's name.
String defaultTableName(String hostName) {
  final name = hostName.trim();
  return name.isEmpty ? 'طاولة' : 'طاولة $name';
}

const defaultCreateSettings = TableSettings(
  startPoints: defaultStartPoints,
  timerSeconds: 0,
);

/// Arabic names in the «إنشاء طاولة» popup, in the requested order.
const createMenuGames = [
  (gameJackaroo, 'جاكارو'),
  (gameLudo, 'لودو'),
  (gameSnakes, 'السلم والثعبان'),
  (gameEcho99, '99'),
  (gameThousandMiles, 'ألف ميل'),
];

/// Creates the table for [game] and opens it. Returns an error text or null.
Future<String?> createAndOpenTable(
  BuildContext context,
  String game, {
  bool offline = false,
  bool replace = false,
}) async {
  final scope = EchoScope.of(context);
  final navigator = Navigator.of(context);
  final hostName = scope.settings.displayName;
  Future<void> open(Widget screen) {
    final route = MaterialPageRoute<void>(builder: (_) => screen);
    return replace ? navigator.pushReplacement(route) : navigator.push(route);
  }

  if (offline) {
    final table = newWaitingTable(
      id: localTableId,
      name: defaultTableName(hostName),
      hostId: scope.settings.playerId,
      hostName: hostName,
      settings: defaultCreateSettings,
      game: game,
    );
    unawaited(
      open(TableScreen(tableId: localTableId, offline: true, initial: table)),
    );
    return null;
  }
  final repo = scope.repo;
  if (repo == null) return 'تعذر الاتصال بـ Firestore';
  try {
      try {
        final uid = FirebaseAuth.instance.currentUser?.uid;
        if (uid != null && uid.isNotEmpty && uid != scope.settings.playerId) {
          await scope.settings.useIdentity(uid);
        }
      } catch (_) {}
    
    final id = await repo.create(
      hostId: scope.settings.playerId,
      hostName: hostName,
      tableName: defaultTableName(hostName),
      settings: defaultCreateSettings,
      game: game,
    );
    unawaited(open(TableScreen(tableId: id)));
    return null;
  } catch (_) {
    return 'تعذر إنشاء الطاولة';
  }
}

/// «إنشاء طاولة» popup: one button per game, then the table opens.
Future<void> showCreateTableDialog(
  BuildContext context, {
  bool offline = false,
}) async {
  final game = await showDialog<String>(
    context: context,
    builder: (dialog) => SimpleDialog(
      title: Semantics(
        header: true,
        child: const Text('إنشاء طاولة — اختر اللعبة'),
      ),
      children: [
        for (final entry in createMenuGames)
          SimpleDialogOption(
            key: Key('create_${entry.$1}'),
            onPressed: () => Navigator.pop(dialog, entry.$1),
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
            child: Text(entry.$2, style: const TextStyle(fontSize: 20)),
          ),
        SimpleDialogOption(
          onPressed: () => Navigator.pop(dialog),
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
          child: const Text('إلغاء'),
        ),
      ],
    ),
  );
  if (game == null || !context.mounted) return;
  final error = await createAndOpenTable(context, game, offline: offline);
  if (error != null && context.mounted) {
    EchoScope.of(context).speech.announce(error);
    ScaffoldMessenger.maybeOf(context)
        ?.showSnackBar(SnackBar(content: Text(error)));
  }
}

class _CreateTableScreenState extends State<CreateTableScreen> {
  var _busy = false;
  String? _error;

  Future<void> _create(String game) async {
    if (_busy) {
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final error = await createAndOpenTable(
      context,
      game,
      offline: widget.offline,
      replace: true,
    );
    if (mounted && error != null) {
      setState(() {
        _busy = false;
        _error = error;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('إنشاء طاولة')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            const Text(
              'اختر اللعبة',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 16),
            for (final entry in createMenuGames) ...[
              ArButton(
                label: entry.$2,
                onPressed: _busy ? null : () => _create(entry.$1),
                fontSize: 20,
              ),
              const SizedBox(height: 12),
            ],
            if (_busy) const Center(child: CircularProgressIndicator()),
            if (_error != null)
              Semantics(
                liveRegion: true,
                child: Text(
                  _error!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Color(0xFFFFB4AB)),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
