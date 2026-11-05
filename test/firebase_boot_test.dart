import 'package:echo99/firebase_options.dart';
import 'package:echo99/services/account.dart';
import 'package:echo99/services/firebase_boot.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('native platforms first init with no options', () async {
    final calls = <FirebaseOptions?>[];
    final boot = await bootFirebase(
      native: true,
      hasApp: () => false,
      init: (options) async => calls.add(options),
    );
    expect(boot.ready, isTrue);
    expect(boot.path, 'native');
    expect(calls, [null]);
  });

  test('duplicate-app means the native [DEFAULT] app is usable', () async {
    var created = false;
    final boot = await bootFirebase(
      native: true,
      hasApp: () => created,
      init: (options) async {
        created = true;
        throw FirebaseException(plugin: 'core', code: 'duplicate-app');
      },
    );
    expect(boot.ready, isTrue);
    expect(boot.path, 'existing');
  });

  test('a failed native init retries once with the native options', () async {
    final calls = <FirebaseOptions?>[];
    final boot = await bootFirebase(
      native: true,
      hasApp: () => false,
      fallback: DefaultFirebaseOptions.android,
      init: (options) async {
        calls.add(options);
        if (options == null) {
          throw FirebaseException(plugin: 'core', code: 'not-initialized');
        }
      },
    );
    expect(boot.ready, isTrue);
    expect(boot.path, 'options');
    expect(calls.length, 2);
    expect(calls.last!.appId, contains(':android:'));
  });

  test('both failing reports both real codes', () async {
    final boot = await bootFirebase(
      native: true,
      hasApp: () => false,
      init: (options) async => throw FirebaseException(
        plugin: 'core',
        code: options == null ? 'no-config' : 'invalid-app-id',
        message: 'boom',
      ),
    );
    expect(boot.ready, isFalse);
    expect(boot.error, contains('core/no-config'));
    expect(boot.error, contains('core/invalid-app-id'));
  });

  test('native fallback options never use the web app id', () {
    expect(DefaultFirebaseOptions.android.appId, contains(':android:'));
    expect(DefaultFirebaseOptions.ios.appId, contains(':ios:'));
    expect(
      DefaultFirebaseOptions.android.appId,
      isNot(DefaultFirebaseOptions.web.appId),
    );
    expect(DefaultFirebaseOptions.android.projectId, 'echo99-9e73b');
  });

  test('login text carries the real init code, not a vague phrase', () {
    final text = firebaseInitMessage('core/no-app: missing config');
    expect(text, contains('core/no-app'));
    expect(text, isNot('Firebase غير جاهز.'));
    expect(firebaseInitMessage(null), contains('firebase/not-initialized'));
  });
}
