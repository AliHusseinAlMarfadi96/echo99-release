import 'package:echo99/services/sign_in_errors.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Google ApiException 10 names the SHA/OAuth problem and its code', () {
    final message = signInErrorMessage(
      PlatformException(
        code: 'sign_in_failed',
        message: 'com.google.android.gms.common.api.ApiException: 10: ',
      ),
    );
    expect(message, contains('SHA-1'));
    expect(message, contains('ApiException 10'));
  });

  test('Firebase errors keep the real code', () {
    final message = signInErrorMessage(
      FirebaseAuthException(code: 'operation-not-allowed'),
    );
    expect(message, contains('firebase/operation-not-allowed'));
    expect(message.toLowerCase(), isNot(contains('service unavailable')));
  });
}
