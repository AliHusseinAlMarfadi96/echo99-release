import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';

import '../firebase_options.dart';

/// Result of starting Firebase. [error] always carries the real
/// `plugin/code: message` so the login screen never shows a vague phrase.
class FirebaseBoot {
  const FirebaseBoot.ready(this.path) : error = null;
  const FirebaseBoot.failed(String this.error) : path = null;

  /// `native`, `existing`, `options`, or `web`.
  final String? path;
  final String? error;

  bool get ready => error == null;
}

typedef FirebaseInit = Future<void> Function(FirebaseOptions? options);

Future<void> _realInit(FirebaseOptions? options) async {
  await Firebase.initializeApp(options: options);
}

bool _realHasApp() => Firebase.apps.isNotEmpty;

/// Android/iOS: Firebase.initializeApp() with no options, so the native SDK
/// reads google-services.json / GoogleService-Info.plist. If that fails and no
/// [DEFAULT] app exists, retry once with the native platform options (never
/// the web app id). Web always uses the web options.
Future<FirebaseBoot> bootFirebase({
  FirebaseInit init = _realInit,
  bool Function() hasApp = _realHasApp,
  bool? native,
  FirebaseOptions? fallback,
}) async {
  final useNative = native ?? DefaultFirebaseOptions.usesNativeConfig;
  if (!useNative) {
    try {
      await init(DefaultFirebaseOptions.currentPlatform);
      return const FirebaseBoot.ready('web');
    } catch (error) {
      return FirebaseBoot.failed(describeFirebaseError(error));
    }
  }
  if (hasApp()) {
    return const FirebaseBoot.ready('existing');
  }
  String first;
  try {
    await init(null);
    return const FirebaseBoot.ready('native');
  } catch (error) {
    first = describeFirebaseError(error);
    debugPrint('Echo99 Firebase native init failed: $first');
  }
  // A duplicate-app error means the native SDK already created [DEFAULT].
  if (hasApp()) {
    return const FirebaseBoot.ready('existing');
  }
  try {
    await init(fallback ?? DefaultFirebaseOptions.currentPlatform);
    return const FirebaseBoot.ready('options');
  } catch (error) {
    if (hasApp()) {
      return const FirebaseBoot.ready('existing');
    }
    final second = describeFirebaseError(error);
    debugPrint('Echo99 Firebase options init failed: $second');
    return FirebaseBoot.failed('$first | $second');
  }
}

String describeFirebaseError(Object error) {
  if (error is FirebaseException) {
    final message = (error.message ?? '').trim();
    final short = message.length > 140
        ? '${message.substring(0, 140)}…'
        : message;
    return short.isEmpty
        ? '${error.plugin}/${error.code}'
        : '${error.plugin}/${error.code}: $short';
  }
  final text = '$error'.trim();
  final short = text.length > 140 ? '${text.substring(0, 140)}…' : text;
  return '${error.runtimeType}: $short';
}
