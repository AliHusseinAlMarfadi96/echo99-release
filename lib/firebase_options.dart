import 'package:firebase_core/firebase_core.dart' show FirebaseOptions;
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;

/// FlutterFire-style options for Firebase project echo99-9e73b.
///
/// Android and iOS are registered apps (com.echo99.echo99). They initialise
/// from the bundled android/app/google-services.json and
/// ios/Runner/GoogleService-Info.plist, so Firebase Auth sees the native app
/// id, API key, and OAuth clients. Earlier builds forced the *web* app id
/// onto Android/iOS: on Android the native SDK had already created [DEFAULT]
/// from google-services.json, so initializeApp(options: web) threw and the
/// login screen only said «Firebase غير جاهز.». The android/ios constants
/// below now carry the real native app ids and are only a fallback.
class DefaultFirebaseOptions {
  /// True on Android and iOS: call Firebase.initializeApp() without options.
  static bool get usesNativeConfig =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  static FirebaseOptions get currentPlatform {
    if (kIsWeb) {
      return web;
    }
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return android;
      case TargetPlatform.iOS:
        return ios;
      case TargetPlatform.macOS:
        return macos;
      default:
        return web;
    }
  }

  static const FirebaseOptions web = FirebaseOptions(
    apiKey: 'AIzaSyAGo1hxStPRwx7oThC6WEh1kmkncexAFfU',
    appId: '1:759151755614:web:ae0f4be7df2a31f1854fcf',
    messagingSenderId: '759151755614',
    projectId: 'echo99-9e73b',
    authDomain: 'echo99-9e73b.firebaseapp.com',
    storageBucket: 'echo99-9e73b.firebasestorage.app',
    databaseURL: 'https://echo99-9e73b-default-rtdb.firebaseio.com',
  );

  /// Native Android app (google-services.json). Fallback only: Android first
  /// calls Firebase.initializeApp() with no options.
  static const FirebaseOptions android = FirebaseOptions(
    apiKey: 'AIzaSyAbePYvGovueEkKQi7y5xG9A3lWZDC45lI',
    appId: '1:759151755614:android:5b9ea273e79574fa854fcf',
    messagingSenderId: '759151755614',
    projectId: 'echo99-9e73b',
    storageBucket: 'echo99-9e73b.firebasestorage.app',
    databaseURL: 'https://echo99-9e73b-default-rtdb.firebaseio.com',
  );

  /// Native iOS app (GoogleService-Info.plist). Fallback only: iOS first
  /// calls Firebase.initializeApp() with no options.
  static const FirebaseOptions ios = FirebaseOptions(
    apiKey: 'AIzaSyDooA9yR1fj1hCesyKK9KpN3Wo-cz3P-zk',
    appId: '1:759151755614:ios:79922d223d674cc2854fcf',
    messagingSenderId: '759151755614',
    projectId: 'echo99-9e73b',
    storageBucket: 'echo99-9e73b.firebasestorage.app',
    databaseURL: 'https://echo99-9e73b-default-rtdb.firebaseio.com',
    iosBundleId: 'com.echo99.echo99',
  );

  static const FirebaseOptions macos = ios;
}
