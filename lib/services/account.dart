import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import 'doc_id.dart';
import 'firebase_boot.dart';
import 'settings_model.dart';
import 'sign_in_errors.dart';

/// Thrown when Google Sign-In cannot run because the Firebase console has
/// not produced an OAuth client id. No client id is invented here.
class AuthConfigException implements Exception {
  const AuthConfigException(this.message);

  final String message;
}

class AccountController extends ChangeNotifier {
  AccountController(
    this.settings, {
    this.firebaseReady = false,
    this.firebaseInitError,
    Future<FirebaseBoot> Function()? rebootFirebase,
  }) : _rebootFirebase = rebootFirebase ?? bootFirebase;

  final SettingsModel settings;

  /// False only while Firebase.initializeApp has not succeeded. Tapping
  /// Google retries the init, so this is never a dead end.
  bool firebaseReady;

  /// The real Firebase.initializeApp error (`plugin/code: message`).
  String? firebaseInitError;

  final Future<FirebaseBoot> Function() _rebootFirebase;

  /// Filled at build time by tool/write_dart_defines.py from
  /// GoogleService-Info.plist and google-services.json. When empty, the
  /// native plugins read the same values from those bundled files.
  static const iosClientId = String.fromEnvironment('GOOGLE_IOS_CLIENT_ID');
  static const webClientId = String.fromEnvironment('GOOGLE_WEB_CLIENT_ID');

  bool ready = false;
  bool signedIn = false;
  bool guest = false;
  bool busy = false;
  String? error;

  /// Set only for a Google sign-in that just succeeded in this process.
  bool linkChime = false;

  StreamSubscription<User?>? _authSub;

  bool takeLinkChime() {
    final value = linkChime;
    linkChime = false;
    return value;
  }

  Future<void> restore() async {
    if (firebaseReady) {
      _authSub = FirebaseAuth.instance.authStateChanges().listen((user) {
        unawaited(_applyAuth(user));
      });
      return;
    }
    // Show the real init failure on the login screen right away.
    error = firebaseInitMessage(firebaseInitError);
    await _applyAuth(null);
  }

  /// Re-read Firebase auth on resume. A signed-out user must see login.
  /// A persisted guest session stays offline and does not bounce to login.
  Future<void> onResume() async {
    if (!firebaseReady) {
      await _applyAuth(null);
      return;
    }
    try {
      await FirebaseAuth.instance.currentUser?.reload();
    } catch (_) {}
    await _applyAuth(FirebaseAuth.instance.currentUser);
  }

  Future<void> _applyAuth(User? user) async {
    final uid = user?.uid;
    if (firebaseReady && uid != null && isSafeDocId(uid)) {
      await _clearGuestFlag();
      await _adopt(uid, _safeName(user?.displayName), asGuest: false);
    } else {
      final prefs = await SharedPreferences.getInstance();
      final guestOn = prefs.getBool('guest_session') == true;
      final guestId = prefs.getString('guest_uid');
      if (guestOn && guestId != null && isSafeDocId(guestId)) {
        await _adopt(guestId, settings.name, asGuest: true);
      } else {
        signedIn = false;
        guest = false;
      }
    }
    ready = true;
    notifyListeners();
  }

  /// Retries Firebase.initializeApp. On success, auth starts listening and
  /// the app creates its Firestore repositories.
  Future<bool> ensureFirebase() async {
    if (firebaseReady) {
      return true;
    }
    final boot = await _rebootFirebase();
    if (!boot.ready) {
      firebaseInitError = boot.error;
      return false;
    }
    firebaseReady = true;
    firebaseInitError = null;
    await _authSub?.cancel();
    _authSub = FirebaseAuth.instance.authStateChanges().listen((user) {
      unawaited(_applyAuth(user));
    });
    notifyListeners();
    return true;
  }

  Future<void> signInWithGoogle() async {
    if (!firebaseReady) {
      busy = true;
      error = null;
      notifyListeners();
      final ok = await ensureFirebase();
      busy = false;
      if (!ok) {
        _fail(firebaseInitMessage(firebaseInitError));
        return;
      }
    }
    await _run(() async {
      // Android: serverClientId is the Web (type 3) OAuth client. When the
      // build did not pass it, the plugin reads default_web_client_id that
      // the google-services plugin generates from google-services.json.
      // iOS: clientId comes from CLIENT_ID in GoogleService-Info.plist (or
      // the dart-define); the REVERSED_CLIENT_ID URL scheme is in Info.plist.
      final google = GoogleSignIn(
        scopes: const ['email', 'profile'],
        // Never pass the iOS client on Android: the Android plugin would
        // treat it as serverClientId and fail with ApiException 10.
        clientId: iosClientId.isEmpty || !_isIos ? null : iosClientId,
        serverClientId: webClientId.isEmpty ? null : webClientId,
      );
      final account = await google.signIn();
      if (account == null) {
        linkChime = false;
        return;
      }
      final auth = await account.authentication;
      final idToken = auth.idToken;
      if (idToken == null || idToken.isEmpty) {
        linkChime = false;
        throw const AuthConfigException(
          'Google لم يُرجع idToken. يلزم معرّف عميل Web (النوع 3) من google-services.json (رمز الخطأ: google/no-id-token).',
        );
      }
      final credential = GoogleAuthProvider.credential(
        idToken: idToken,
        accessToken: auth.accessToken,
      );
      linkChime = true;
      final result = await FirebaseAuth.instance.signInWithCredential(
        credential,
      );
      final uid = result.user?.uid;
      if (uid == null || !isSafeDocId(uid)) {
        linkChime = false;
        throw StateError('unsafe uid');
      }
      await _clearGuestFlag();
      await _adopt(
        uid,
        _safeName(result.user?.displayName ?? account.displayName),
        asGuest: false,
      );
    });
  }

  static bool get _isIos =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;

  Future<void> continueAsGuest() async {
    await _run(() async {
      linkChime = false;
      final prefs = await SharedPreferences.getInstance();
      var id = prefs.getString('guest_uid');
      if (id == null || !isSafeDocId(id)) {
        id = 'guest${const Uuid().v4().replaceAll('-', '')}';
        await prefs.setString('guest_uid', id);
      }
      await prefs.setBool('guest_session', true);
      await _adopt(id, settings.name, asGuest: true);
    });
  }

  Future<void> signOut() async {
    linkChime = false;
    await _clearGuestFlag();
    signedIn = false;
    guest = false;
    error = null;
    notifyListeners();
    try {
      if (firebaseReady) {
        await FirebaseAuth.instance.signOut();
        try {
          await GoogleSignIn().signOut();
        } catch (_) {}
      }
    } catch (_) {}
  }

  Future<void> _adopt(String uid, String? name, {required bool asGuest}) async {
    requireDocId(uid);
    await settings.useIdentity(uid);
    final trimmed = (name ?? '').trim();
    if (trimmed.isNotEmpty && settings.name.trim().isEmpty) {
      await settings.setName(trimmed);
    }
    guest = asGuest;
    signedIn = true;
    error = null;
  }

  Future<void> _run(Future<void> Function() body) async {
    busy = true;
    error = null;
    notifyListeners();
    try {
      await body();
    } on AuthConfigException catch (error) {
      linkChime = false;
      this.error = error.message;
    } catch (caught) {
      linkChime = false;
      error = signInErrorMessage(caught);
      debugPrint('Echo99 sign-in failed: $error');
    } finally {
      busy = false;
      ready = true;
      notifyListeners();
    }
  }

  void _fail(String message) {
    linkChime = false;
    error = message;
    ready = true;
    notifyListeners();
  }

  Future<void> _clearGuestFlag() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('guest_session', false);
  }

  String? _safeName(String? value) {
    final trimmed = (value ?? '').trim();
    if (trimmed.isEmpty || trimmed.contains('@')) {
      return null;
    }
    return trimmed;
  }

  @override
  void dispose() {
    _authSub?.cancel();
    super.dispose();
  }
}

/// Login-screen text for a failed Firebase.initializeApp. Always includes the
/// real code so the user (and support) can see what actually failed.
String firebaseInitMessage(String? code) {
  final detail = (code == null || code.trim().isEmpty)
      ? 'firebase/not-initialized'
      : code.trim();
  return 'تعذر تشغيل Firebase على هذا الجهاز، لذلك لا يمكن تسجيل الدخول بحساب Google الآن. '
      'أعد المحاولة أو تابع كضيف. (رمز الخطأ: $detail)';
}
