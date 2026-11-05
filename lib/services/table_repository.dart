import 'dart:math';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:uuid/uuid.dart';

import '../game/engine.dart';
import '../game/engine.dart' as engine;
import '../game/jackaroo.dart';
import '../game/lifecycle.dart';
import '../game/rules.dart';
import '../game/snakes.dart';
import '../game/ludo.dart';
import '../game/thousand_miles.dart';
import 'local_match.dart' show nextBotName;

class TableSummary {
  const TableSummary({
    required this.id,
    required this.name,
    required this.playerCount,
    required this.status,
    this.hostId = '',
    this.game = gameEcho99,
  });

  final String id;
  final String name;
  final int playerCount;
  final String status;
  final String hostId;
  final String game;
}

/// A persisted table log / chat / system entry.
class TableLogEntry {
  const TableLogEntry({
    required this.id,
    required this.kind,
    required this.text,
    required this.atMillis,
    this.authorId = '',
    this.authorName = '',
  });

  /// kind: play | chat | system
  final String id;
  final String kind;
  final String text;
  final int atMillis;
  final String authorId;
  final String authorName;

  Map<String, dynamic> toMap() => {
    'kind': kind,
    'text': text,
    'atMillis': atMillis,
    'authorId': authorId,
    'authorName': authorName,
  };

  static TableLogEntry fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final data = doc.data() ?? const <String, dynamic>{};
    return TableLogEntry(
      id: doc.id,
      kind: '${data['kind'] ?? 'system'}',
      text: '${data['text'] ?? ''}',
      atMillis: (data['atMillis'] as num?)?.toInt() ?? 0,
      authorId: '${data['authorId'] ?? ''}',
      authorName: '${data['authorName'] ?? ''}',
    );
  }
}

class TableRepository {
  TableRepository({FirebaseFirestore? firestore})
    : _db = firestore ?? FirebaseFirestore.instance;

  final FirebaseFirestore _db;
  final Random _random = Random.secure();

  CollectionReference<Map<String, dynamic>> get _tables =>
      _db.collection('tables');

  CollectionReference<Map<String, dynamic>> _log(String tableId) =>
      _tables.doc(tableId).collection('log');

  /// Known subcollections under a table document. Deleted with the table so
  /// Firestore never keeps orphan hosts after AppLifecycle / leave.
  static const tableSubcollections = ['log'];

  /// Liveness fields written with every table change and by the host
  /// heartbeat. `expireAt` is the Firestore TTL field (a TTL policy on
  /// tables.expireAt deletes abandoned documents server-side once enabled).
  static Map<String, dynamic> _liveness() {
    final now = DateTime.now().millisecondsSinceEpoch;
    return {
      'heartbeatAt': now,
      'expireAt': Timestamp.fromMillisecondsSinceEpoch(now + ghostTableMs * 4),
    };
  }

  /// A table whose host stopped heart-beating for this long is a ghost.
  static const ghostTableMs = 5 * 60 * 1000;

  /// True when the stored table looks abandoned at [nowMillis].
  static bool isGhost(Map<String, dynamic> data, int nowMillis) {
    final beat = (data['heartbeatAt'] as num?)?.toInt();
    if (beat != null) return nowMillis - beat > ghostTableMs;
    final created = data['createdAt'];
    if (created is Timestamp) {
      // Tables from older builds (no heartbeat): ghost after 6 hours.
      return nowMillis - created.millisecondsSinceEpoch > 6 * 3600 * 1000;
    }
    return false;
  }

  /// Host keeps its table alive (every 60 s while the table screen is open,
  /// also when minimized thanks to the foreground service / audio mode).
  Future<void> heartbeat(String tableId) async {
    try {
      await _tables.doc(tableId).update(_liveness());
    } catch (_) {}
  }

  final Set<String> _sweeping = {};

  /// Any client that sees a ghost table deletes it inside a transaction
  /// (re-checked server-side data), then its log. Best-effort.
  Future<void> sweepGhost(String tableId) async {
    if (!_sweeping.add(tableId)) return;
    try {
      final ref = _tables.doc(tableId);
      final gone = await _db.runTransaction((tx) async {
        final snap = await tx.get(ref);
        final data = snap.data();
        if (data == null) return false;
        if (!isGhost(data, DateTime.now().millisecondsSinceEpoch)) {
          return false;
        }
        tx.delete(ref);
        return true;
      });
      if (gone) {
        await _deleteCollection(ref.collection('log'));
      }
    } catch (_) {
    } finally {
      _sweeping.remove(tableId);
    }
  }

  Stream<List<TableSummary>> watchTables() {
    return _tables.orderBy('createdAt', descending: true).snapshots().map((
      snapshot,
    ) {
      final now = DateTime.now().millisecondsSinceEpoch;
      for (final doc in snapshot.docs) {
        if (isGhost(doc.data(), now)) {
          sweepGhost(doc.id);
        }
      }
      return [
        for (final doc in snapshot.docs)
          if (!isGhost(doc.data(), now))
            TableSummary(
              id: doc.id,
              name: '${doc.data()['name'] ?? 'طاولة'}',
              playerCount:
                  ((doc.data()['players'] as List?) ?? const []).length,
              status: '${doc.data()['status'] ?? 'waiting'}',
              hostId: '${doc.data()['hostId'] ?? ''}',
              game: supportedGames.contains(doc.data()['game'])
                  ? '${doc.data()['game']}'
                  : gameEcho99,
            ),
      ];
    });
  }

  Stream<MatchState?> watchTable(String id) {
    return _tables.doc(id).snapshots().map((doc) {
      if (!doc.exists || doc.data() == null) {
        return null;
      }
      return MatchState.fromMap(doc.data()!, doc.id);
    });
  }

  Stream<List<TableLogEntry>> watchLog(String tableId) {
    return _log(tableId)
        .orderBy('atMillis', descending: false)
        .snapshots()
        .map(
          (snap) => [for (final doc in snap.docs) TableLogEntry.fromDoc(doc)],
      //   ).handleError((_) {})
 ).handleError((_) {});;;  
}

  Future<String?> appendLog({
    required String tableId,
    required String kind,
    required String text,
    String authorId = '',
    String authorName = '',
  }) async {
    if (kind == 'chat' && authorId.isNotEmpty) {
      final blocked = await _mutate(tableId, (state) {
        final seat = state.players.where((s) => s.id == authorId).firstOrNull;
        final legacy = [
          for (final id in (state.board['blockedChat'] as List? ?? const []))
            '$id',
        ];
        if (seat?.chatBlocked == true || legacy.contains(authorId)) {
          return const _Err('الدردشة محظورة من المضيف');
        }
        return _Ok(state, changed: false);
      });
      if (blocked != null) return blocked;
    }
        final payload = {
               'kind': kind,
               'text': text,
      'atMillis': DateTime.now().millisecondsSinceEpoch,
      'authorId': authorId,
      'authorName': authorName,
    };
    try {
      await _log(tableId).add(payload);
    } catch (_) {
      try {
        await _db.collection('log').add({...payload, 'tableId': tableId});
      } catch (_) {}
    }
    
    return null;
  }

  Future<String> create({
    required String hostId,
    required String hostName,
    required String tableName,
    required TableSettings settings,
    String game = gameEcho99,
  }) async {
    final id = const Uuid().v4();
    final state = newWaitingTable(
      id: id,
      name: tableName,
      hostId: hostId,
      hostName: hostName,
      settings: settings,
      game: game,
    );
    await _tables.doc(id).set({
      ...state.toMap(),
      'createdAt': FieldValue.serverTimestamp(),
      ..._liveness(),
    });
    await appendLog(
      tableId: id,
      kind: 'system',
      text: '$hostName أنشأ الطاولة',
      authorId: hostId,
      authorName: hostName,
    );
    return id;
  }

  /// Host-only, before the start. Every seated client sees it via the stream.
  Future<String?> updateSettings({
    required String tableId,
    required String hostId,
    required TableSettings settings,
  }) {
    return _mutate(tableId, (state) {
      if (state.hostId != hostId) {
        return const _Err('فقط المضيف يستطيع تغيير الإعدادات');
      }
      return _from(applySettings(state, settings));
    });
  }

  /// Null means the player is seated. `watch` means the table opened without a seat.
  Future<String?> join({
    required String tableId,
    required String playerId,
    required String playerName,
  }) async {
    final error = await _mutate(tableId, (state) {
      if (state.players.any((seat) => seat.id == playerId)) {
        return _Ok(state);
      }
      if (state.status != 'waiting') {
        return const _Ok.watch();
      }
      final cap = maxSeatsFor(state.game);
      if (state.players.length >= cap) {
        return _Err('الحد $cap لاعبين.');
      }
      final players = [
        ...state.players,
        Seat(
          id: playerId,
          name: playerName,
          points: state.maxPoints,
          isBot: false,
        ),
      ];
      return _Ok(_replace(state, players: players));
    });
    if (error == null) {
      await appendLog(
        tableId: tableId,
        kind: 'system',
        text: '$playerName انضم إلى الطاولة',
        authorId: playerId,
        authorName: playerName,
      );
    }
    return error;
  }

  /// Guests remove themselves. Host deletes the whole table + subcollections.
  Future<String?> leave({
    required String tableId,
    required String playerId,
  }) async {
    MatchState? snapshot;
    try {
      final snap = await _tables.doc(tableId).get();
      if (!snap.exists || snap.data() == null) {
        return null;
      }
      snapshot = MatchState.fromMap(snap.data()!, tableId);
    } catch (_) {
      return 'تعذر حفظ الطاولة';
    }
    final action = tableLeaveAction(
      hostId: snapshot.hostId,
      playerId: playerId,
    );
    if (action == TableLeaveAction.deleteTable) {
      await deleteTableCompletely(tableId);
      return null;
    }
    final name = snapshot.players
        .where((seat) => seat.id == playerId)
        .map((seat) => seat.name)
        .firstOrNull;
    final error = await _mutate(tableId, (state) {
      final seat = state.players.where((s) => s.id == playerId).firstOrNull;
      if (seat == null) {
        return _Ok(state, changed: false);
      }
      final now = DateTime.now().millisecondsSinceEpoch;
      if (state.status == 'playing') {
        // Mid-game leave: a bot takes the seat and the match continues.
        return _from(
          replaceWithBot(
            state,
            playerId,
            botId: _botId(),
            botName: 'بوت (${seat.name})',
            nowMillis: now,
          ),
        );
      }
      return _from(kickPlayer(state, playerId, now));
    });
    if (error == null && name != null) {
      await appendLog(
        tableId: tableId,
        kind: 'system',
        text: '$name غادر الطاولة',
        authorId: playerId,
        authorName: name,
      );
    }
    return error;
  }

  /// Deletes the table document and every known subcollection document.
  /// Firestore has no onDisconnect().removeValue — callers must invoke this
  /// when the host leaves, closes, or detaches.
  Future<void> deleteTableCompletely(String tableId) async {
    final ref = _tables.doc(tableId);
    for (final name in tableSubcollections) {
      await _deleteCollection(ref.collection(name));
    }
    await ref.delete();
  }

  Future<void> _deleteCollection(
    CollectionReference<Map<String, dynamic>> col,
  ) async {
    while (true) {
      final snap = await col.limit(200).get();
      if (snap.docs.isEmpty) {
        return;
      }
      final batch = _db.batch();
      for (final doc in snap.docs) {
        batch.delete(doc.reference);
      }
      await batch.commit();
    }
  }

  Future<String?> kick({
    required String tableId,
    required String hostId,
    required String targetId,
  }) {
    return _mutate(tableId, (state) {
      if (state.hostId != hostId) {
        return const _Err('فقط المضيف يستطيع الطرد');
      }
      if (targetId == hostId) {
        return const _Err('لا يمكنك طرد نفسك');
      }
      final now = DateTime.now().millisecondsSinceEpoch;
      final seat = state.players.where((s) => s.id == targetId).firstOrNull;
      if (seat != null && state.status == 'playing' && !seat.isBot) {
        return _from(
          replaceWithBot(
            state,
            targetId,
            botId: _botId(),
            botName: 'بوت (${seat.name})',
            nowMillis: now,
          ),
        );
      }
      return _from(kickPlayer(state, targetId, now));
    });
  }

  String _botId() => 'bot${const Uuid().v4().replaceAll('-', '')}';

  Future<String?> addBot({required String tableId, required String hostId}) {
    return _mutate(tableId, (state) {
      if (state.hostId != hostId) {
        return const _Err('فقط المضيف يستطيع إضافة بوت');
      }
      if (state.players.length >= maxSeatsFor(state.game)) {
        return _Err('الحد ${maxSeatsFor(state.game)} لاعبين.');
      }
      return _from(engine.addBot(state, _botId(), nextBotName(state)));
    });
  }

  Future<String?> start({required String tableId, required String hostId}) {
    return _mutate(tableId, (state) {
      if (state.hostId != hostId) {
        return const _Err('فقط المضيف يستطيع البدء');
      }
      return _from(
        startGame(state, _random, DateTime.now().millisecondsSinceEpoch),
      );
    });
  }

  /// Host-only Jackaroo mode + timer before the start.
  Future<String?> updateJackarooSettings({
    required String tableId,
    required String hostId,
    required String mode,
    required int timerSeconds,
  }) {
    return _mutate(tableId, (state) {
      if (state.hostId != hostId) {
        return const _Err('فقط المضيف يستطيع تغيير الإعدادات');
      }
      return _from(applyJackarooMode(state, mode, timerSeconds));
    });
  }

  /// Snakes timer before the start.
  Future<String?> updateTimer({
    required String tableId,
    required String hostId,
    required int timerSeconds,
  }) {
    return _mutate(tableId, (state) {
      if (state.hostId != hostId) {
        return const _Err('فقط المضيف يستطيع تغيير الإعدادات');
      }
      if (state.status != 'waiting') {
        return const _Err('لا يمكن تغيير الإعدادات بعد البدء');
      }
      return _Ok(
        state.copyWith(timerSeconds: timerSeconds, nonce: state.nonce + 1),
      );
    });
  }

  /// «إعادة اللعب» — host only, after the match finished. Restarts at once
  /// with the same players and settings.
  Future<String?> replay({required String tableId, required String hostId}) {
    return _mutate(tableId, (state) {
      if (state.hostId != hostId) {
        return const _Err('فقط المضيف يستطيع إعادة اللعب');
      }
      final reset = resetForReplay(state);
      if (reset.error != null) {
        return _Err(reset.error!);
      }
      return _from(
        startGame(reset.state, _random, DateTime.now().millisecondsSinceEpoch),
      );
    });
  }

  Future<String?> playJackarooMove({
    required String tableId,
    required String playerId,
    required JackarooMove move,
  }) {
    return _mutate(tableId, (state) {
      return _from(
        playJackaroo(
          state,
          playerId: playerId,
          move: move,
          random: _random,
          nowMillis: DateTime.now().millisecondsSinceEpoch,
        ),
      );
    });
  }

  /// The die is rolled inside the Firestore transaction (Random.secure), so
  /// the client only asks to roll and never chooses the number.
  Future<String?> rollDice({
    required String tableId,
    required String playerId,
  }) {
    return _mutate(tableId, (state) {
      final roll = rollDie(_random);
      final now = DateTime.now().millisecondsSinceEpoch;
      if (state.game == gameLudo) {
        return _from(
          rollLudo(state, playerId: playerId, roll: roll, nowMillis: now),
        );
      }
      return _from(
        rollSnakes(state, playerId: playerId, roll: roll, nowMillis: now),
      );
    });
  }

  Future<String?> moveLudoPiece({
    required String tableId,
    required String playerId,
    required int piece,
  }) {
    return _mutate(tableId, (state) {
      return _from(
        moveLudo(
          state,
          playerId: playerId,
          piece: piece,
          nowMillis: DateTime.now().millisecondsSinceEpoch,
        ),
      );
    });
  }

  Future<String?> chooseLudoColor({
    required String tableId,
    required String playerId,
    required int colorIndex,
  }) {
    return _mutate(tableId, (state) {
      return _from(
        pickLudoColor(
          state,
          playerId: playerId,
          colorIndex: colorIndex,
          nowMillis: DateTime.now().millisecondsSinceEpoch,
        ),
      );
    });
  }

  Future<String?> updateLudoSettings({
    required String tableId,
    required String hostId,
    required LudoSettings settings,
  }) {
    return _mutate(tableId, (state) {
      if (state.hostId != hostId) {
        return const _Err('فقط المضيف يستطيع تغيير الإعدادات');
      }
      return _from(applyLudoSettings(state, settings));
    });
  }

  Future<String?> updateMilesSettings({
    required String tableId,
    required String hostId,
    required MilesSettings settings,
  }) {
    return _mutate(tableId, (state) {
      if (state.hostId != hostId) {
        return const _Err('فقط المضيف يستطيع تغيير الإعدادات');
      }
      return _from(applyMilesSettings(state, settings));
    });
  }

  Future<String?> drawMilesCard({
    required String tableId,
    required String playerId,
  }) {
    return _mutate(tableId, (state) {
      return _from(
        drawMiles(
          state,
          playerId: playerId,
          random: _random,
          nowMillis: DateTime.now().millisecondsSinceEpoch,
        ),
      );
    });
  }

  /// Coup-fourré holder declines, or the auto-draw window ran out.
  Future<String?> closeMilesCoupWindow({
    required String tableId,
    required String playerId,
  }) {
    return _mutate(tableId, (state) {
      return _from(
        closeMilesCoup(
          state,
          playerId: playerId,
          random: _random,
          nowMillis: DateTime.now().millisecondsSinceEpoch,
        ),
      );
    });
  }

  /// Coup fourré: the holder plays the matching safety out of turn.
  Future<String?> coupFourreMilesCard({
    required String tableId,
    required String playerId,
    required String card,
  }) {
    return _mutate(tableId, (state) {
      return _from(
        coupFourreMiles(
          state,
          playerId: playerId,
          card: card,
          random: _random,
          nowMillis: DateTime.now().millisecondsSinceEpoch,
        ),
      );
    });
  }

  Future<String?> playMilesCard({
    required String tableId,
    required String playerId,
    required String card,
    String? targetId,
    bool discardOnly = false,
  }) {
    return _mutate(tableId, (state) {
      return _from(
        playMiles(
          state,
          playerId: playerId,
          card: card,
          targetId: targetId,
          discardOnly: discardOnly,
          random: _random,
          nowMillis: DateTime.now().millisecondsSinceEpoch,
        ),
      );
    });
  }

  /// Host mute / block-chat flags on the board (clients enforce locally).
  Future<String?> hostSeatControl({
    required String tableId,
    required String hostId,
    required String targetId,
    required String
    action, // mute | unmute | blockChat | unblockChat | replaceBot
  }) {
    return _mutate(tableId, (state) {
      if (state.hostId != hostId) {
        return const _Err('فقط المضيف');
      }
      if (targetId == hostId) {
        return const _Err('لا يمكنك تطبيق هذا على نفسك');
      }
      final now = DateTime.now().millisecondsSinceEpoch;
      if (action == 'replaceBot') {
        final seat = state.players.where((s) => s.id == targetId).firstOrNull;
        if (seat == null) return const _Err('اللاعب غير موجود');
        return _from(
          replaceWithBot(
            state,
            targetId,
            botId: _botId(),
            botName: 'بوت (${seat.name})',
            nowMillis: now,
          ),
        );
      }
      final index = state.players.indexWhere((s) => s.id == targetId);
      if (index < 0) {
        return const _Err('اللاعب غير موجود');
      }
      final players = [...state.players];
      final seat = players[index];
      if (action == 'mute') {
        players[index] = seat.copyWith(micMuted: true);
      } else if (action == 'unmute') {
        players[index] = seat.copyWith(micMuted: false);
      } else if (action == 'blockChat') {
        players[index] = seat.copyWith(chatBlocked: true);
      } else if (action == 'unblockChat') {
        players[index] = seat.copyWith(chatBlocked: false);
      } else {
        return const _Err('إجراء غير معروف');
      }
      // Keep legacy board lists in sync for older clients.
      final board = Map<String, dynamic>.from(state.board);
      board['mutedMics'] = [
        for (final s in players)
          if (s.micMuted) s.id,
      ];
      board['blockedChat'] = [
        for (final s in players)
          if (s.chatBlocked) s.id,
      ];
      return _Ok(
        state.copyWith(players: players, board: board, nonce: state.nonce + 1),
      );
    });
  }

  /// Presence lost for [playerId]: keep seat/score, show «Reconnecting...».
  Future<String?> markReconnecting({
    required String tableId,
    required String playerId,
  }) {
    return _mutate(tableId, (state) {
      final result = markReconnectingSeat(
        state,
        playerId,
        DateTime.now().millisecondsSinceEpoch,
      );
      if (result.error != null) {
        return _Ok(state, changed: false);
      }
      return _Ok(result.state, changed: !identical(result.state, state));
    });
  }

  Future<String?> markReconnected({
    required String tableId,
    required String playerId,
  }) {
    return _mutate(tableId, (state) {
      final result = markReconnectedSeat(state, playerId);
      if (result.error != null) {
        return _Ok(state, changed: false);
      }
      return _Ok(result.state, changed: !identical(result.state, state));
    });
  }

  /// Host sweeps expired grace windows: bot-replace (playing) or remove.
  Future<String?> expireGrace({
    required String tableId,
    required String hostId,
  }) {
    return _mutate(tableId, (state) {
      if (state.hostId != hostId) {
        return _Ok(state, changed: false);
      }
      final result = expireGraceSeats(
        state,
        nowMillis: DateTime.now().millisecondsSinceEpoch,
        botIdFor: (_) => _botId(),
      );
      if (result == null) {
        return _Ok(state, changed: false);
      }
      return _Ok(result.state);
    });
  }

  Future<String?> play({
    required String tableId,
    required String playerId,
    required String card,
    int? choice,
  }) {
    return _mutate(tableId, (state) {
      return _from(
        playCard(
          state,
          playerId: playerId,
          cardCode: card,
          choice: choice,
          random: _random,
          nowMillis: DateTime.now().millisecondsSinceEpoch,
        ),
      );
    });
  }

  Future<void> rename({
    required String tableId,
    required String playerId,
    required String playerName,
  }) async {
    await _mutate(tableId, (state) {
      final index = state.players.indexWhere((seat) => seat.id == playerId);
      if (index < 0 || state.players[index].name == playerName) {
        return _Ok(state, changed: false);
      }
      final players = [...state.players];
      players[index] = players[index].copyWith(name: playerName);
      return _Ok(_replace(state, players: players));
    });
  }

  Future<String?> _mutate(
    String tableId,
    _Step Function(MatchState state) step,
  ) async {
    try {
      return await _db.runTransaction((tx) async {
        final ref = _tables.doc(tableId);
        final snap = await tx.get(ref);
        if (!snap.exists || snap.data() == null) {
          return 'الطاولة غير موجودة';
        }
        final state = MatchState.fromMap(snap.data()!, tableId);
        final result = step(state);
        if (result is _Err) {
          return result.message;
        }
        final ok = result as _Ok;
        if (ok.watchOnly) {
          return 'watch';
        }
        if (ok.changed && ok.state != null) {
          tx.set(ref, {
            ...ok.state!.toMap(),
            'createdAt': snap.data()!['createdAt'],
            ..._liveness(),
          });
        }
        return null;
      });
    } catch (_) {
      return 'تعذر حفظ الطاولة';
    }
  }
}

MatchState _replace(MatchState state, {required List<Seat> players}) {
  return MatchState(
    id: state.id,
    name: state.name,
    players: players,
    hostId: state.hostId,
    status: state.status,
    pile: state.pile,
    lastCard: state.lastCard,
    turnIndex: state.turnIndex,
    direction: state.direction,
    maxPoints: state.maxPoints,
    timerSeconds: state.timerSeconds,
    teamsEnabled: state.teamsEnabled,
    teams: state.teams,
    deck: state.deck,
    discard: state.discard,
    hands: state.hands,
    lastPlay: state.lastPlay,
    cue: state.cue,
    winnerId: state.winnerId,
    nonce: state.nonce,
    turnStartedAt: state.turnStartedAt,
    game: state.game,
    board: state.board,
  );
}

_Step _from(EngineResult result) {
  if (result.error != null) {
    return _Err(result.error!);
  }
  return _Ok(result.state);
}

sealed class _Step {
  const _Step();
}

class _Ok extends _Step {
  const _Ok(this.state, {this.changed = true}) : watchOnly = false;
  const _Ok.watch() : state = null, changed = false, watchOnly = true;

  final MatchState? state;
  final bool changed;
  final bool watchOnly;
}

class _Err extends _Step {
  const _Err(this.message);
  final String message;
}
