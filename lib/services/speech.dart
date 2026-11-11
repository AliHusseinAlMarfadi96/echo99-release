import 'package:flutter/semantics.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
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
      // A wedged TTS engine must not hold the presentation queue forever:
      // cap the completion wait, and on timeout stop the shared session so
      // the next utterance starts clean.
      final speaking = _tts?.speak(text);
      if (speaking != null) {
        await speaking.timeout(
          const Duration(seconds: 15),
          onTimeout: () async {
            await _tts?.stop();
          },
        );
      }
    } catch (_) {}
  }

  /// iOS VoiceOver supplies an actual announcement-finished callback.
  /// Other screen readers expose submission only; never claim their speech
  /// completed from the Semantics future alone.
  Future<void> ordered(String text, {required bool useInternalTts}) async {
    if (useInternalTts) {
      await say(text, useInternalTts: true);
      return;
    }
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS) {
      try {
        await const MethodChannel('echo99/speech_completion')
            .invokeMethod<void>('announce', text)
            .timeout(
              const Duration(seconds: 90),
              onTimeout: () async {
                await cancelOrdered();
              },
            );
        return;
      } on MissingPluginException {
        // Non-iOS test hosts and older app shells.
      }
    }
    announce(text);
  }

  Future<void> cancelOrdered() async {
    // Internal TTS has its own completion future and must stop on background.
    await _tts?.stop();
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS) {
      try {
        await const MethodChannel('echo99/speech_completion')
            .invokeMethod<void>('cancel');
      } on MissingPluginException {
        // No native speech callback is pending on this platform.
      }
    }
  }

  void announce(String text) {
    final view = WidgetsBinding.instance.platformDispatcher.implicitView;
    if (view == null) {
      return;
    }
    SemanticsService.sendAnnouncement(view, text, TextDirection.rtl);
  }
}
