import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/services.dart';

/// Arabic sign-in errors that always carry the real code, so a failure is
/// never reported as a vague "service unavailable".
String signInErrorMessage(Object error) {
  if (error is FirebaseAuthException) {
    final reason = switch (error.code) {
      'network-request-failed' =>
        'لا يوجد اتصال بالإنترنت أو انقطع الاتصال بخوادم Firebase.',
      'invalid-credential' =>
        'رفض Firebase بيانات Google. تحقق من بصمة SHA ومعرّف العميل.',
      'operation-not-allowed' =>
        'تسجيل الدخول بحساب Google غير مفعّل في Firebase Authentication.',
      'user-disabled' => 'هذا الحساب معطّل في Firebase.',
      'account-exists-with-different-credential' =>
        'هذا البريد مرتبط بطريقة دخول أخرى.',
      'too-many-requests' => 'محاولات كثيرة. انتظر قليلاً ثم أعد المحاولة.',
      'app-not-authorized' =>
        'التطبيق غير مصرّح له باستخدام Firebase Authentication.',
      'internal-error' => 'خطأ داخلي في Firebase Authentication.',
      _ => 'رفض Firebase تسجيل الدخول.',
    };
    return _withCode(reason, 'firebase/${error.code}', error.message);
  }
  if (error is PlatformException) {
    final api = apiExceptionCode(error);
    if (api != null) {
      final reason = switch (api) {
        7 => 'خطأ في الشبكة أثناء تسجيل الدخول بحساب Google.',
        8 => 'خطأ داخلي في خدمات Google Play. أعد المحاولة.',
        10 => 'إعداد Google غير مطابق: بصمة SHA-1 أو اسم الحزمة أو معرّف عميل Web في Firebase.',
        12500 => 'فشل تسجيل الدخول بحساب Google. حدّث خدمات Google Play وتحقق من إعداد OAuth.',
        12501 => 'أُلغي تسجيل الدخول.',
        12502 => 'تسجيل دخول آخر قيد التنفيذ.',
        1 ||
        2 ||
        3 ||
        9 ||
        18 => 'خدمات Google Play غير متوفرة أو تحتاج إلى تحديث على هذا الجهاز.',
        _ => 'تعذر تسجيل الدخول بحساب Google.',
      };
      return _withCode(reason, 'google/${error.code}/ApiException $api', null);
    }
    final reason = switch (error.code) {
      'network_error' => 'خطأ في الشبكة أثناء تسجيل الدخول بحساب Google.',
      'sign_in_canceled' => 'أُلغي تسجيل الدخول.',
      'sign_in_required' => 'يلزم تسجيل الدخول بحساب Google.',
      'failed_to_recover_auth' => 'تعذر استرداد صلاحية حساب Google.',
      'user_recoverable_auth' => 'يحتاج حساب Google إلى تأكيد من المستخدم.',
      _ => 'تعذر تسجيل الدخول بحساب Google.',
    };
    return _withCode(reason, 'google/${error.code}', error.message);
  }
  return _withCode(
    'تعذر تسجيل الدخول.',
    error.runtimeType.toString(),
    '$error',
  );
}

/// Pulls N out of "com.google.android.gms.common.api.ApiException: N: ...".
int? apiExceptionCode(PlatformException error) {
  final text = '${error.message ?? ''} ${error.details ?? ''}';
  final match = RegExp(r'ApiException:\s*(\d+)').firstMatch(text);
  return match == null ? null : int.tryParse(match.group(1)!);
}

String _withCode(String reason, String code, String? detail) {
  final extra = (detail ?? '').trim();
  final short = extra.length > 160 ? '${extra.substring(0, 160)}…' : extra;
  return short.isEmpty
      ? '$reason (رمز الخطأ: $code)'
      : '$reason (رمز الخطأ: $code — $short)';
}
