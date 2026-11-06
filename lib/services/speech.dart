import 'package:flutter/semantics.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_tts/flutter_tts.dart';

import 'audio_policy.dart';

/// Screen-reader announcements always; flutter_tts only when enabled.
class Speech {
  FlutterTts? _tts;
  var _ready = false;

  Future<void> _ensureTts() async {
    if (_ready) {
      return;
    }
    _tts ??= FlutterTts();
    try {
      await _tts!.setLanguage('ar-SA');
      await _tts!.setSharedInstance(true);
      await _tts!.autoStopSharedSession(false);
      await _tts!.setSpeechRate(0.48);
      await _tts!.awaitSpeakCompletion(true);
    } catch (_) {}
    _ready = true;
  }

  /// Internal TTS only when the setting is on. Never touches flutter_tts
  /// when [useInternalTts] is false (TalkBack / VoiceOver handle speech).
  Future<void> say(String text, {required bool useInternalTts}) async {
    if (!useInternalTts) {
      return;
    }
    await _ensureTts();
    try {
      await _tts?.stop();
      final input = GameAudioPolicy.shared.needsInput;
      await _tts?.setIosAudioCategory(
        input
            ? IosTextToSpeechAudioCategory.playAndRecord
            : IosTextToSpeechAudioCategory.playback,
        const [IosTextToSpeechAudioCategoryOptions.mixWithOthers],
        input
            ? IosTextToSpeechAudioMode.voiceChat
            : IosTextToSpeechAudioMode.spokenAudio,
      );
      await _tts?.speak(text);
    } catch (_) {}
  }

  void announce(String text) {
    final view = WidgetsBinding.instance.platformDispatcher.implicitView;
    if (view == null) {
      return;
    }
    SemanticsService.sendAnnouncement(view, text, TextDirection.rtl);
  }
}
