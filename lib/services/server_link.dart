import 'dart:async';

/// Echo99 has two remote services with different roles:
///
/// * Firestore (project echo99-9e73b) is the required online server. Tables,
///   friends, presence, and the signed-in session all live there. If it
///   answers, the player is online.
/// * LiveKit is voice chat only. It is best-effort: a voice failure must never
///   block the menu or make Google sign-in look broken.
///
/// Before 1.0.5 both had to succeed, so a LiveKit hiccup showed «فشل الاتصال
/// بالسيرفر» right after a successful Google sign-in.
const voiceUnavailableNote =
    'الصوت غير متاح حالياً. الطاولات تعمل عبر السيرفر بشكل طبيعي، ويمكنك اللعب بدون محادثة صوتية.';

const voiceRetryLabel = 'إعادة الاتصال الصوتي';

class TableServerResult {
  const TableServerResult.online(int this.latencyMs) : error = null;
  const TableServerResult.failed(String this.error) : latencyMs = null;

  final int? latencyMs;
  final String? error;

  bool get online => latencyMs != null;
}

/// Probes the required table server (a Firestore write + server read).
Future<TableServerResult> reachTableServer(
  Future<int> Function() probe, {
  Duration timeout = const Duration(seconds: 20),
}) async {
  try {
    final ms = await probe().timeout(timeout);
    return TableServerResult.online(ms);
  } on TimeoutException {
    return const TableServerResult.failed('firestore/timeout');
  } catch (error) {
    return TableServerResult.failed('firestore/${error.runtimeType}');
  }
}

/// Best-effort voice warmup. Null means voice is ready.
///
/// [attempt] returns an Arabic error for a configuration problem (for example
/// a build without the LiveKit secret); that is not retried. A thrown error or
/// timeout is a network/cloud failure and is retried up to [attempts] times.
Future<String?> warmVoiceBestEffort(
  Future<String?> Function() attempt, {
  int attempts = 2,
  Duration timeout = const Duration(seconds: 12),
  Duration retryDelay = const Duration(seconds: 2),
}) async {
  for (var i = 0; i < attempts; i++) {
    try {
      final error = await attempt().timeout(timeout);
      return error;
    } catch (_) {
      if (i + 1 < attempts) {
        await Future<void>.delayed(retryDelay);
      }
    }
  }
  return voiceUnavailableNote;
}
