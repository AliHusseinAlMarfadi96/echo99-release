import 'package:audioplayers/audioplayers.dart';
import 'package:livekit_client/livekit_client.dart';

/// Shared session intent for game sounds, TTS and the LiveKit capture path.
/// Native recording state remains authoritative during asynchronous stop,
/// mute and reconnect transitions. A pending start also reserves input so
/// a sound cannot select playback-only while recording is being enabled.
class GameAudioPolicy {
  GameAudioPolicy({bool Function()? nativeRecording})
    : _nativeRecording =
          nativeRecording ??
          (() {
            // Pinned LiveKit 2.13 API; native capture state is required here.
            // ignore: experimental_member_use
            return AudioManager.instance.audioEngineState.isRecordingEnabled;
          });
  static final shared = GameAudioPolicy();
  final bool Function() _nativeRecording;
  bool captureRequested = false;
  bool get needsInput => captureRequested || _nativeRecording();

  AudioContext get soundContext => AudioContext(
    iOS: AudioContextIOS(
      category: needsInput
          ? AVAudioSessionCategory.playAndRecord
          : AVAudioSessionCategory.playback,
      options: const {AVAudioSessionOptions.mixWithOthers},
    ),
    android: const AudioContextAndroid(
      isSpeakerphoneOn: false,
      stayAwake: false,
      contentType: AndroidContentType.sonification,
      usageType: AndroidUsageType.assistanceSonification,
      audioFocus: AndroidAudioFocus.none,
    ),
  );
}
