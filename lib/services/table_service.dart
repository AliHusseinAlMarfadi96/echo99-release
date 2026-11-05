import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Android foreground service (microphone / media playback) that keeps the
/// process and LiveKit alive while the player sits at an active table with
/// the screen locked or the app minimized. iOS relies on UIBackgroundModes
/// audio + fetch instead, so this is a no-op there.
class TableForegroundService {
  static const _channel = MethodChannel('echo99/table_service');
  static var _running = false;

  static bool get _android =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  static Future<void> start(String title) async {
    if (!_android) {
      return;
    }
    try {
      await _channel.invokeMethod<bool>('start', {'title': title});
      _running = true;
    } catch (error) {
      debugPrint('Echo99 foreground service failed: $error');
    }
  }

  static Future<void> stop() async {
    if (!_android || !_running) {
      return;
    }
    try {
      await _channel.invokeMethod<bool>('stop');
    } catch (_) {}
    _running = false;
  }
}
