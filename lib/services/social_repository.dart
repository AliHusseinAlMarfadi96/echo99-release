import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:uuid/uuid.dart';

import 'doc_id.dart';

class OnlinePlayer {
  const OnlinePlayer({required this.uid, required this.name});

  final String uid;
  final String name;
}

class Friend {
  const Friend({required this.uid, required this.name});

  final String uid;
  final String name;
}

class TableInvite {
  const TableInvite({
    required this.id,
    required this.fromUid,
    required this.fromName,
    required this.tableId,
  });

  final String id;
  final String fromUid;
  final String fromName;
  final String tableId;
}

class FriendRequest {
  const FriendRequest({required this.fromUid, required this.name});

  final String fromUid;
  final String name;
}

class PrivateMessage {
  const PrivateMessage({
    required this.id,
    required this.fromUid,
    required this.fromName,
    required this.toUid,
    required this.text,
    required this.atMillis,
  });

  final String id;
  final String fromUid;
  final String fromName;
  final String toUid;
  final String text;
  final int atMillis;
}

class SocialRepository {
  SocialRepository({FirebaseFirestore? firestore})
    : _db = firestore ?? FirebaseFirestore.instance;

  final FirebaseFirestore _db;

  Future<void> setOnline({
    required String uid,
    required String name,
    required bool online,
  }) async {
    requireDocId(uid);
    await _db.collection('presence').doc(uid).set({
      'name': name,
      'online': online,
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  Stream<List<OnlinePlayer>> watchOnline() {
    return _db
        .collection('presence')
        .where('online', isEqualTo: true)
        .snapshots()
        .map((snapshot) {
          return [
            for (final doc in snapshot.docs)
              if (isSafeDocId(doc.id))
                OnlinePlayer(
                  uid: doc.id,
                  name: '${doc.data()['name'] ?? 'لاعب'}',
                ),
          ];
        });
  }

  Future<void> follow({
    required String uid,
    required String friendUid,
    required String name,
  }) async {
    requireDocId(uid);
    requireDocId(friendUid);
    await _db
        .collection('users')
        .doc(uid)
        .collection('friends')
        .doc(friendUid)
        .set({'name': name, 'followedAt': FieldValue.serverTimestamp()});
    try {
      await _db
          .collection('users')
          .doc(friendUid)
          .collection('friendRequests')
          .doc(uid)
          .set({
            'fromUid': uid,
            'name': name,
            'createdAt': FieldValue.serverTimestamp(),
          });
    } catch (_) {}
  }

  Future<void> unfollow({
    required String uid,
    required String friendUid,
  }) async {
    requireDocId(uid);
    requireDocId(friendUid);
    await _db
        .collection('users')
        .doc(uid)
        .collection('friends')
        .doc(friendUid)
        .delete();
  }

  Stream<List<Friend>> watchFriends(String uid) {
    requireDocId(uid);
    return _db
        .collection('users')
        .doc(uid)
        .collection('friends')
        .snapshots()
        .map((snapshot) {
          return [
            for (final doc in snapshot.docs)
              if (isSafeDocId(doc.id))
                Friend(uid: doc.id, name: '${doc.data()['name'] ?? 'لاعب'}'),
          ];
        });
  }

  Future<void> invite({
    required String fromUid,
    required String toUid,
    required String fromName,
    required String tableId,
  }) async {
    requireDocId(fromUid);
    requireDocId(toUid);
    requireDocId(tableId);
    final id = '${fromUid}_$toUid';
    await _db.collection('invites').doc(id).set({
      'fromUid': fromUid,
      'toUid': toUid,
      'fromName': fromName,
      'tableId': tableId,
      'createdAt': FieldValue.serverTimestamp(),
    });
  }

  Stream<List<TableInvite>> watchInvites(String uid) {
    requireDocId(uid);
    return _db
        .collection('invites')
        .where('toUid', isEqualTo: uid)
        .snapshots()
        .map((snapshot) {
          return [
            for (final doc in snapshot.docs)
              if (isSafeDocId('${doc.data()['tableId'] ?? ''}'))
                TableInvite(
                  id: doc.id,
                  fromUid: '${doc.data()['fromUid'] ?? ''}',
                  fromName: '${doc.data()['fromName'] ?? 'لاعب'}',
                  tableId: '${doc.data()['tableId']}',
                ),
          ];
        });
  }

  Stream<Set<String>> watchFriendRequests(String uid) {
    requireDocId(uid);
    return _db
        .collection('users')
        .doc(uid)
        .collection('friendRequests')
        .snapshots()
        .map((snapshot) {
          return {
            for (final doc in snapshot.docs)
              if (isSafeDocId(doc.id)) doc.id,
          };
        });
  }

  Future<void> sendPrivateMessage({
    required String fromUid,
    required String toUid,
    required String fromName,
    required String text,
  }) async {
    requireDocId(fromUid);
    requireDocId(toUid);
    final body = text.trim();
    if (body.isEmpty) {
      return;
    }
    final id = const Uuid().v4().replaceAll('-', '');
    await _db
        .collection('users')
        .doc(toUid)
        .collection('privateMessages')
        .doc(id)
        .set({
          'fromUid': fromUid,
          'fromName': fromName,
          'text': body,
          'createdAt': FieldValue.serverTimestamp(),
        });
  }

  Stream<Set<String>> watchPrivateMessages(String uid) {
    requireDocId(uid);
    return _db
        .collection('users')
        .doc(uid)
        .collection('privateMessages')
        .snapshots()
        .map((snapshot) => {for (final doc in snapshot.docs) doc.id});
  }

  /// Profile dialog «إرسال طلب صداقة»: writes users/{to}/friendRequests/{me}.
  Future<void> sendFriendRequest({
    required String fromUid,
    required String fromName,
    required String toUid,
  }) async {
    requireDocId(fromUid);
    requireDocId(toUid);
    await _db
        .collection('users')
        .doc(toUid)
        .collection('friendRequests')
        .doc(fromUid)
        .set({
          'fromUid': fromUid,
          'name': fromName,
          'createdAt': FieldValue.serverTimestamp(),
        });
  }

  Stream<List<FriendRequest>> watchFriendRequestList(String uid) {
    requireDocId(uid);
    return _db
        .collection('users')
        .doc(uid)
        .collection('friendRequests')
        .snapshots()
        .map(
          (snapshot) => [
            for (final doc in snapshot.docs)
              if (isSafeDocId(doc.id))
                FriendRequest(
                  fromUid: doc.id,
                  name: '${doc.data()['name'] ?? 'لاعب'}',
                ),
          ],
        );
  }

  /// Accept: both users list each other in users/{uid}/friends.
  Future<void> acceptFriendRequest({
    required String uid,
    required String name,
    required String fromUid,
    required String fromName,
  }) async {
    requireDocId(uid);
    requireDocId(fromUid);
    final batch = _db.batch();
    batch.set(
      _db.collection('users').doc(uid).collection('friends').doc(fromUid),
      {'name': fromName, 'followedAt': FieldValue.serverTimestamp()},
    );
    batch.set(
      _db.collection('users').doc(fromUid).collection('friends').doc(uid),
      {'name': name, 'followedAt': FieldValue.serverTimestamp()},
    );
    batch.delete(
      _db
          .collection('users')
          .doc(uid)
          .collection('friendRequests')
          .doc(fromUid),
    );
    await batch.commit();
  }

  Future<void> declineFriendRequest({
    required String uid,
    required String fromUid,
  }) async {
    requireDocId(uid);
    requireDocId(fromUid);
    await _db
        .collection('users')
        .doc(uid)
        .collection('friendRequests')
        .doc(fromUid)
        .delete();
  }

  Stream<List<PrivateMessage>> watchPrivateMessageList(String uid) {
    requireDocId(uid);
    return _db
        .collection('users')
        .doc(uid)
        .collection('privateMessages')
        .snapshots()
        .map((snapshot) {
          final list = [
            for (final doc in snapshot.docs)
              PrivateMessage(
                id: doc.id,
                fromUid: '${doc.data()['fromUid'] ?? ''}',
                fromName: '${doc.data()['fromName'] ?? 'لاعب'}',
                toUid: uid,
                text: '${doc.data()['text'] ?? ''}',
                atMillis:
                    (doc.data()['createdAt'] as Timestamp?)
                        ?.millisecondsSinceEpoch ??
                    0,
              ),
          ];
          list.sort((a, b) => a.atMillis.compareTo(b.atMillis));
          return list;
        });
  }

  /// Server round trip. Returns milliseconds. Throws if Firestore is unreachable.
  Future<int> measureLatency(String uid) async {
    requireDocId(uid);
    final ref = _db.collection('latency').doc(uid);
    final watch = Stopwatch()..start();
    await ref.set({'at': FieldValue.serverTimestamp()});
    await ref.get(const GetOptions(source: Source.server));
    watch.stop();
    return watch.elapsedMilliseconds;
  }
}
