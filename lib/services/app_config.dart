import 'package:cloud_firestore/cloud_firestore.dart';

import '../app_version.dart';
import 'doc_id.dart';

class AppUpdate {
  const AppUpdate({
    required this.required,
    required this.androidUrl,
    required this.iosUrl,
  });

  final bool required;
  final String androidUrl;
  final String iosUrl;

  static const none = AppUpdate(required: false, androidUrl: '', iosUrl: '');
}

class AppConfigRepository {
  AppConfigRepository({FirebaseFirestore? firestore})
      : _db = firestore ?? FirebaseFirestore.instance;

  final FirebaseFirestore _db;

  static const docId = 'release';

  Future<AppUpdate> load() async {
    requireDocId(docId);
    final ref = _db.collection('app_config').doc(docId);
    DocumentSnapshot<Map<String, dynamic>> snap;
    try {
      snap = await ref
          .get(const GetOptions(source: Source.server))
          .timeout(const Duration(seconds: 12));
    } catch (_) {
      return AppUpdate.none;
    }
    if (!snap.exists || snap.data() == null) {
      try {
        await ref.set({
          'latest_app_version': appVersion,
          'force_update_required': true,
          'update_url_android': androidUpdateUrl,
          'update_url_ios': iosUpdateUrl,
        });
      } catch (_) {}
      return AppUpdate.none;
    }
    final data = snap.data()!;
    final latest = '${data['latest_app_version'] ?? ''}';
    final force = data['force_update_required'] != false;
    return AppUpdate(
      required: forceUpdateBlocks(
        localVersion: appVersion,
        latestVersion: latest,
        forceUpdateRequired: force,
      ),
      androidUrl: '${data['update_url_android'] ?? androidUpdateUrl}',
      iosUrl: '${data['update_url_ios'] ?? iosUpdateUrl}',
    );
  }
}
