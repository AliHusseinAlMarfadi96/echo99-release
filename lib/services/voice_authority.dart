import 'package:cloud_firestore/cloud_firestore.dart';

import 'voice_token_transport.dart';

/// One entry in a voice room's member map. Mirrors the shape the Firestore
/// rules enforce on voiceRooms/{tableId}: exactly these three booleans.
class VoiceMember {
  const VoiceMember({
    required this.muted,
    required this.banned,
    required this.present,
  });

  final bool muted;
  final bool banned;
  final bool present;

  Map<String, dynamic> toMap() => {
    'muted': muted,
    'banned': banned,
    'present': present,
  };

  /// Strict parse: anything malformed is treated as absent (fail closed).
  static VoiceMember? fromMap(Object? value) {
    if (value is! Map) return null;
    final muted = value['muted'];
    final banned = value['banned'];
    final present = value['present'];
    if (muted is! bool || banned is! bool || present is! bool) return null;
    return VoiceMember(muted: muted, banned: banned, present: present);
  }
}

/// Self-join admission (owner's chosen policy, rules v5.2): any signed-in
/// user who opens a table creates ONLY their own listener entry, forced
/// {muted:false, banned:false}. The rules deny self-join when an entry
/// already exists, so host mutes and bans always survive. The table's
/// players list is never consulted for voice.
bool canSelfJoinListener(Map<String, VoiceMember> existing, String uid) {
  // Dotted ids would write nested 'members.<id>' field paths - never valid.
  return !uid.contains('.') && !existing.containsKey(uid);
}

/// Client for the voiceRooms authority collection. The Firestore rules are
/// the enforcement boundary; this class only writes the shapes the rules
/// already constrain, so a bug here fails closed (permission-denied),
/// never open. Admission is self-join (owner's policy, rules v5.2): a
/// signed-in user creates only their own absent listener entry, forced
/// unmuted/unbanned; their later writes only flip `present`. Moderation
/// (mute/ban/unban) stays host-only.
/// Thrown when the durable moderation write already landed but live-room
/// enforcement through the issuer failed. Nothing retries this
/// automatically (LiveKit refreshes connected clients server-side without
/// re-asking the issuer), so the caller must surface it and let the host
/// retry.
class VoiceModerationException implements Exception {
  const VoiceModerationException(this.op, this.targetId);

  final String op;
  final String targetId;

  @override
  String toString() => 'live moderation failed: $op $targetId';
}

/// Live-room enforcement through the issuer. A null transport (endpoint
/// not configured) skips enforcement; a transport failure throws
/// [VoiceModerationException].
Future<void> enforceLiveModeration(
  VoiceTokenTransport? transport, {
  required String tableId,
  required String targetId,
  required String op,
}) async {
  if (transport == null) return;
  try {
    await transport.moderate(tableId: tableId, targetId: targetId, op: op);
  } catch (_) {
    throw VoiceModerationException(op, targetId);
  }
}

/// User-facing text for a failed host voice action. A
/// [VoiceModerationException] means the durable write LANDED and only the
/// live-room enforcement failed (retry re-applies it). Any other error
/// means nothing was saved; the message must not claim otherwise.
String voiceActionFailureText(Object error, String action) {
  if (error is VoiceModerationException) {
    // Reached only after the durable write succeeded.
    return 'حُفظ $action، لكن تعذّر تطبيقه على المشارك المتصل الآن';
  }
  if (error is FirebaseException && error.code == 'permission-denied') {
    // A verified server-side reject: the write did not happen.
    return 'رُفض حفظ $action — لم يُحفظ أي تغيير';
  }
  // Timeouts/network errors can commit-then-lose-ack: never assert a
  // negative from them; ask the host to refresh state before retrying.
  return 'تعذّر التأكد من حفظ $action — حدّث الحالة قبل إعادة المحاولة';
}

class VoiceAuthority {
  VoiceAuthority(this._db, {this.transport});

  final FirebaseFirestore _db;

  /// Null when the issuer endpoint is unconfigured: durable entry writes
  /// still land, live-room enforcement is skipped.
  final VoiceTokenTransport? transport;

  CollectionReference<Map<String, dynamic>> get _rooms =>
      _db.collection('voiceRooms');

  /// Watches the room document. Null means no room exists for the table
  /// (legacy table or not yet created).
  Stream<DocumentSnapshot<Map<String, dynamic>>> watchRoom(String tableId) =>
      _rooms.doc(tableId).snapshots();

  /// Stages the room document inside [batch] so table + voice room are
  /// created atomically (the rules bind the room to the table's hostId via
  /// getAfter, which only holds within one commit).
  static void stageRoomCreate(
    FirebaseFirestore db,
    WriteBatch batch, {
    required String tableId,
    required String hostId,
  }) {
    batch.set(db.collection('voiceRooms').doc(tableId), {
      'hostId': hostId,
      'generation': 1,
      'createdAt': FieldValue.serverTimestamp(),
      'members': {
        hostId: const VoiceMember(
          muted: false,
          banned: false,
          present: false,
        ).toMap(),
      },
    });
  }

  // No lazy room creation for legacy tables: under the old rules any
  // signed-in user could rewrite a table's hostId, so the recorded host of
  // a pre-deploy table is not a verified original owner. Voice rooms exist
  // only for tables created under the new rules (stageRoomCreate above),
  // unless the owner explicitly decides otherwise.

  /// Self-join as listener on opening a table: creates the caller's own
  /// entry only when absent (rules v5.2 force muted/banned false and deny
  /// the write when any entry exists, so tombstones and mutes hold).
  /// No-op for legacy tables (no room doc) and existing members.
  Future<void> ensureSelfListener({
    required String tableId,
    required String uid,
  }) async {
    final ref = _rooms.doc(tableId);
    final snap = await ref.get();
    if (!snap.exists) return;
    if (!canSelfJoinListener(parseMembers(snap.data()), uid)) return;
    await ref.update({
      'members.$uid': const VoiceMember(
        muted: false,
        banned: false,
        present: false,
      ).toMap(),
    });
  }

  /// Member marks themselves present/absent in the voice session. The
  /// rules freeze mute/ban on self-writes; fails closed for non-members.
  Future<void> setPresent({
    required String tableId,
    required String uid,
    required bool present,
  }) async {
    final ref = _rooms.doc(tableId);
    final snap = await ref.get();
    final current = parseMembers(snap.data())[uid];
    if (current == null) return;
    await ref.update({
      'members.$uid': VoiceMember(
        muted: current.muted,
        banned: current.banned,
        present: present,
      ).toMap(),
    });
  }

  /// Host mutes/unmutes a member: durable entry write first, then live-room
  /// enforcement through the issuer. A failed enforcement throws
  /// [VoiceModerationException] AFTER the durable write landed; the caller
  /// surfaces it and the host retries.
  Future<void> setMuted({
    required String tableId,
    required String targetId,
    required bool muted,
  }) async {
    await _hostWrite(
      tableId,
      targetId,
      (m) => VoiceMember(muted: muted, banned: m.banned, present: m.present),
    );
    await _moderate(tableId: tableId, targetId: targetId, op: muted ? 'mute' : 'unmute');
  }

  /// Host kick: persistent ban tombstone (muted+banned+absent), then live
  /// removal. The tombstone blocks every future token; a failed live
  /// removal throws [VoiceModerationException] after the write landed.
  Future<void> kick({
    required String tableId,
    required String targetId,
  }) async {
    await _hostWrite(
      tableId,
      targetId,
      (m) => const VoiceMember(muted: true, banned: true, present: false),
    );
    await _moderate(tableId: tableId, targetId: targetId, op: 'kick');
  }

  /// Host lifts a ban: the member returns as absent and still muted (a
  /// deliberate unmute is a separate host action), matching the rules.
  Future<void> unban({
    required String tableId,
    required String targetId,
  }) async {
    await _hostWrite(
      tableId,
      targetId,
      (m) => const VoiceMember(muted: true, banned: false, present: false),
    );
  }

  /// Host deletes the room when the table itself is deleted.
  Future<void> deleteRoom(String tableId) => _rooms.doc(tableId).delete();

  Future<void> _hostWrite(
    String tableId,
    String targetId,
    VoiceMember Function(VoiceMember) update,
  ) async {
    final ref = _rooms.doc(tableId);
    final snap = await ref.get();
    final current = parseMembers(snap.data())[targetId];
    if (current == null) return;
    await ref.update({'members.$targetId': update(current).toMap()});
  }

  Future<void> _moderate({
    required String tableId,
    required String targetId,
    required String op,
  }) =>
      enforceLiveModeration(
        transport,
        tableId: tableId,
        targetId: targetId,
        op: op,
      );

  static Map<String, VoiceMember> parseMembers(Map<String, dynamic>? data) {
    final members = data?['members'];
    if (members is! Map) return {};
    final result = <String, VoiceMember>{};
    members.forEach((key, value) {
      final member = VoiceMember.fromMap(value);
      if (key is String && member != null) result[key] = member;
    });
    return result;
  }
}
