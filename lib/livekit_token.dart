import 'package:dart_jsonwebtoken/dart_jsonwebtoken.dart';

/// Non-secret LiveKit coordinates. The API secret is never stored here.
class LiveKitConfig {
  static const url = String.fromEnvironment(
    'LIVEKIT_URL',
    defaultValue: 'wss://echo99-0o54hspu.livekit.cloud',
  );
  static const apiKey = String.fromEnvironment(
    'LIVEKIT_API_KEY',
    defaultValue: 'APIKw29rPMTjQSy',
  );
}

/// Mints a LiveKit room-join JWT.
///
/// [apiSecret] must come from the compile-time `LIVEKIT_API_SECRET` define
/// (empty unless the app is built with `--dart-define` or a gitignored
/// defines file). An empty secret returns null and does not invent a token.
String? mintLiveKitToken({
  required String apiKey,
  required String apiSecret,
  required String identity,
  required String displayName,
  required String room,
}) {
  if (apiSecret.isEmpty) {
    return null;
  }
  final jwt = JWT(
    {
      'name': displayName,
      'video': {
        'room': room,
        'roomJoin': true,
        'canPublish': true,
        'canSubscribe': true,
        'canPublishData': true,
      },
    },
    issuer: apiKey,
    subject: identity,
  );
  return jwt.sign(SecretKey(apiSecret), expiresIn: const Duration(hours: 6));
}

String? mintConfiguredToken({
  required String identity,
  required String displayName,
  required String room,
}) {
  return mintLiveKitToken(
    apiKey: LiveKitConfig.apiKey,
    apiSecret: const String.fromEnvironment('LIVEKIT_API_SECRET'),
    identity: identity,
    displayName: displayName,
    room: room,
  );
}
