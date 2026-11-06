/// Client for the server-minted LiveKit voice token (functions/mintVoiceToken).
///
/// NOT WIRED YET: VoiceRoom still uses mintConfiguredToken (client-side JWT).
/// Activation is a separate slice after the owner deploys the function:
/// bind `_defaultCall` to
/// `FirebaseFunctions.instance.httpsCallable('mintVoiceToken')` (adds the
/// cloud_functions package) and call [mint] before joining, then again at
/// [VoiceToken.refreshAfter] while the room stays open.
///
/// Grant semantics: the server binds the token to the table's room and sets
/// canPublish=false for host-muted seats. Grants are static for the token's
/// lifetime, so a host mute lands two ways: instantly on every connected
/// client via the existing voice.applyHostMutes listener, and durably at
/// the next token refresh (server re-reads the seat flags on every call).
library;

/// One server call. Returns the decoded response map.
typedef VoiceTokenCall = Future<Map<String, dynamic>> Function(String tableId);

class VoiceToken {
  const VoiceToken({
    required this.token,
    required this.canPublish,
    required this.refreshAfter,
  });

  /// The signed LiveKit JWT, bound to the table's room.
  final String token;

  /// False when the seat is host-muted: join listen-only.
  final bool canPublish;

  /// Re-call the endpoint at or before this moment; the server re-reads
  /// seat flags (host mute/unmute) on every call, so refreshing is what
  /// makes durable grant changes reach the room.
  final DateTime refreshAfter;
}

class VoiceTokenException implements Exception {
  const VoiceTokenException(this.message);
  final String message;
  @override
  String toString() => 'VoiceTokenException: $message';
}

class VoiceTokenClient {
  VoiceTokenClient({VoiceTokenCall? call, DateTime Function()? now})
    : _call = call ?? _unboundCall,
      _now = now ?? DateTime.now;

  final VoiceTokenCall _call;
  final DateTime Function() _now;

  /// Refresh at 80% of the server TTL so a network retry still fits inside
  /// the old token's validity.
  static const refreshFraction = 0.8;

  static Future<Map<String, dynamic>> _unboundCall(String tableId) {
    throw const VoiceTokenException(
      'voice token endpoint is not bound yet (function not deployed)',
    );
  }

  Future<VoiceToken> mint(String tableId) async {
    if (tableId.isEmpty) {
      throw const VoiceTokenException('tableId is required');
    }
    final Map<String, dynamic> res;
    try {
      res = await _call(tableId);
    } catch (e) {
      throw VoiceTokenException('token call failed: $e');
    }
    final token = res['token'];
    final ttl = res['expiresInSeconds'];
    if (token is! String || token.isEmpty) {
      throw const VoiceTokenException('server returned no token');
    }
    if (ttl is! int || ttl <= 0) {
      throw const VoiceTokenException('server returned no expiry');
    }
    final lifetime = Duration(milliseconds: (ttl * 1000 * refreshFraction).round());
    return VoiceToken(
      token: token,
      canPublish: res['canPublish'] != false,
      refreshAfter: _now().add(lifetime),
    );
  }
}
