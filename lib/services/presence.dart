import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/foundation.dart';

import 'doc_id.dart';
import 'social_repository.dart' show OnlinePlayer;

/// Realtime Database URL for project echo99-9e73b (also in firebase_options,
/// google-services.json, and GoogleService-Info.plist).
const presenceDatabaseUrl = 'https://echo99-9e73b-default-rtdb.firebaseio.com';

/// RTDB presence. Unlike Firestore, RTDB runs `onDisconnect()` on the
/// server when the socket dies, so:
/// * `status/{uid}` is the online list (removed on disconnect);
/// * `tables/{tableId}/seats/{uid}` marks a seated, connected player;
/// * `tables/{tableId}/host` + `hosting/{uid}` point at the host's live table.
/// When the host's socket drops, those vanish and remaining clients start
/// the 60 s grace, then cascade-delete the Firestore table.
class PresenceService {
  PresenceService({FirebaseDatabase? database}) : _injected = database;

  final FirebaseDatabase? _injected;
  FirebaseDatabase? _db;
  StreamSubscription<DatabaseEvent>? _connectedSub;
  final _connected = StreamController<bool>.broadcast();
  bool _isConnected = false;
  bool _everConnected = false;
  String? _uid;
  String? _name;
  String? _tableId;
  bool _tableHost = false;

  bool get connected => _isConnected;

  /// True once RTDB answered at least once. Until then, presence-driven
  /// cleanup stays off so a missing RTDB instance never kicks anybody.
  bool get available => _everConnected;

  Stream<bool> get connection => _connected.stream;

  FirebaseDatabase? get _database {
    if (_db != null) {
      return _db;
    }
    try {
      _db =
          _injected ??
          FirebaseDatabase.instanceFor(
            app: Firebase.app(),
            databaseURL: presenceDatabaseUrl,
          );
    } catch (error) {
      debugPrint('Echo99 RTDB unavailable: $error');
      _db = null;
    }
    return _db;
  }

  /// Signed-in user is online. Re-registers onDisconnect on every reconnect.
  Future<void> goOnline({required String uid, required String name}) async {
    if (!isSafeDocId(uid)) {
      return;
    }
    _uid = uid;
    _name = name;
    final db = _database;
    if (db == null) {
      return;
    }
    _connectedSub ??= db.ref('.info/connected').onValue.listen((event) {
      final now = event.snapshot.value == true;
      final was = _isConnected;
      _isConnected = now;
      if (now) {
        _everConnected = true;
      }
      if (now != was) {
        _connected.add(now);
      }
      if (now) {
        unawaited(_register());
      }
    }, onError: (_) {});
    await _register();
  }

  Future<void> _register() async {
    final db = _database;
    final uid = _uid;
    if (db == null || uid == null) {
      return;
    }
    try {
      final status = db.ref('status/$uid');
      await status.onDisconnect().remove();
      await status.set({
        'name': _name ?? '',
        'online': true,
        'at': ServerValue.timestamp,
      });
      final table = _tableId;
      if (table != null) {
        await _registerTable(db, uid, table, _tableHost);
      }
    } catch (error) {
      debugPrint('Echo99 presence write failed: $error');
    }
  }

  Future<void> _registerTable(
    FirebaseDatabase db,
    String uid,
    String tableId,
    bool host,
  ) async {
    final seat = db.ref('tables/$tableId/seats/$uid');
    await seat.onDisconnect().remove();
    await seat.set({'name': _name ?? '', 'at': ServerValue.timestamp});
    if (host) {
      final hostRef = db.ref('tables/$tableId/host');
      final pointer = db.ref('hosting/$uid');
      // Host socket dies → the table's host presence + the hosting pointer
      // are deleted server-side; guests then run the 60 s grace and
      // cascade-delete the Firestore table (and this RTDB node).
      await hostRef.onDisconnect().remove();
      await pointer.onDisconnect().remove();
      await hostRef.set(uid);
      await pointer.set(tableId);
    }
  }

  Future<void> goOffline() async {
    final db = _database;
    final uid = _uid;
    await leaveTable();
    if (db == null || uid == null) {
      return;
    }
    try {
      await db.ref('status/$uid').onDisconnect().cancel();
      await db.ref('status/$uid').remove();
    } catch (_) {}
  }

  Future<void> joinTable({required String tableId, required bool host}) async {
    if (!isSafeDocId(tableId)) {
      return;
    }
    _tableId = tableId;
    _tableHost = host;
    final db = _database;
    final uid = _uid;
    if (db == null || uid == null) {
      return;
    }
    try {
      await _registerTable(db, uid, tableId, host);
    } catch (error) {
      debugPrint('Echo99 table presence failed: $error');
    }
  }

  Future<void> leaveTable() async {
    final db = _database;
    final uid = _uid;
    final tableId = _tableId;
    final host = _tableHost;
    _tableId = null;
    _tableHost = false;
    if (db == null || uid == null || tableId == null) {
      return;
    }
    try {
      final seat = db.ref('tables/$tableId/seats/$uid');
      await seat.onDisconnect().cancel();
      await seat.remove();
      if (host) {
        await db.ref('tables/$tableId/host').onDisconnect().cancel();
        await db.ref('hosting/$uid').onDisconnect().cancel();
        await db.ref('tables/$tableId').remove();
        await db.ref('hosting/$uid').remove();
      }
    } catch (_) {}
  }

  /// Cascade cleanup of a table's RTDB node after its Firestore doc is gone.
  Future<void> removeTable(String tableId) async {
    final db = _database;
    if (db == null || !isSafeDocId(tableId)) {
      return;
    }
    try {
      await db.ref('tables/$tableId').remove();
    } catch (_) {}
  }

  /// Connected seat ids for a table.
  Stream<Set<String>> watchSeats(String tableId) {
    final db = _database;
    if (db == null || !isSafeDocId(tableId)) {
      return const Stream.empty();
    }
    return db.ref('tables/$tableId/seats').onValue.map((event) {
      final value = event.snapshot.value;
      if (value is Map) {
        return {for (final key in value.keys) '$key'};
      }
      return <String>{};
    });
  }

  /// Host id while the host's socket is alive, else null.
  Stream<String?> watchHost(String tableId) {
    final db = _database;
    if (db == null || !isSafeDocId(tableId)) {
      return const Stream.empty();
    }
    return db.ref('tables/$tableId/host').onValue.map((event) {
      final value = event.snapshot.value;
      return value == null ? null : '$value';
    });
  }

  /// RTDB online list (server removes entries when sockets die).
  Stream<List<OnlinePlayer>> watchOnline() {
    final db = _database;
    if (db == null) {
      return Stream.error(StateError('rtdb'));
    }
    return db.ref('status').onValue.map((event) {
      final value = event.snapshot.value;
      if (value is! Map) {
        return const <OnlinePlayer>[];
      }
      return [
        for (final entry in value.entries)
          if (isSafeDocId('${entry.key}'))
            OnlinePlayer(
              uid: '${entry.key}',
              name: entry.value is Map
                  ? '${(entry.value as Map)['name'] ?? 'لاعب'}'
                  : 'لاعب',
            ),
      ];
    });
  }

  Future<void> dispose() async {
    await _connectedSub?.cancel();
    _connectedSub = null;
    await _connected.close();
  }
}

/// Pure decision used by the table screen: which seats just dropped and
/// which came back, comparing two RTDB snapshots against the human seats.
({Set<String> dropped, Set<String> returned}) presenceDiff({
  required Set<String> seenBefore,
  required Set<String> now,
  required Set<String> humans,
}) {
  final dropped = {
    for (final id in seenBefore)
      if (!now.contains(id) && humans.contains(id)) id,
  };
  final returned = {
    for (final id in now)
      if (humans.contains(id)) id,
  };
  return (dropped: dropped, returned: returned);
}

/// Online players from RTDB (authoritative: server drops dead sockets).
/// Falls back to the Firestore `presence` collection when RTDB errors or
/// stays silent for [wait] (e.g. the RTDB instance is not provisioned).
Stream<List<OnlinePlayer>> onlinePlayers({
  required PresenceService presence,
  required Stream<List<OnlinePlayer>> Function() firestore,
  Duration wait = const Duration(seconds: 5),
}) {
  late StreamController<List<OnlinePlayer>> controller;
  StreamSubscription<List<OnlinePlayer>>? rtdb;
  StreamSubscription<List<OnlinePlayer>>? fallback;
  Timer? timer;
  var gotRtdb = false;
  void useFallback() {
    if (fallback != null || controller.isClosed) {
      return;
    }
    rtdb?.cancel();
    fallback = firestore().listen(controller.add, onError: controller.addError);
  }

  controller = StreamController<List<OnlinePlayer>>(
    onListen: () {
      rtdb = presence.watchOnline().listen((list) {
        gotRtdb = true;
        timer?.cancel();
        controller.add(list);
      }, onError: (_) => useFallback());
      timer = Timer(wait, () {
        if (!gotRtdb) {
          useFallback();
        }
      });
    },
    onCancel: () async {
      timer?.cancel();
      await rtdb?.cancel();
      await fallback?.cancel();
    },
  );
  return controller.stream;
}
