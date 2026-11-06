import 'dart:async';

import 'audio_policy.dart';

import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart' as ja;
import 'package:livekit_client/livekit_client.dart';

abstract class SoundPlayer {
  Stream<void> get completed;
  Future<void> playAsset(String path, {bool loop = false});
  Future<void> stop();
  Future<void> dispose();
}

/// Supported activation opt-out: this player never owns the RTC session.
/// Audio interruption/noisy-route handling remains enabled in just_audio.
class ManagedSoundPlayer implements SoundPlayer {
  ManagedSoundPlayer({Future<void> Function()? prepareSession})
    : _prepareSession = prepareSession ?? prepareIdleSoundSession;
  final Future<void> Function() _prepareSession;
  final ja.AudioPlayer _player = ja.AudioPlayer(
    handleAudioSessionActivation: false,
  );
  bool _disposed = false;
  int _generation = 0;

  @override
  Stream<void> get completed => _player.processingStateStream
      .where((state) => state == ja.ProcessingState.completed)
      .map((_) {});

  @override
  Future<void> playAsset(String path, {bool loop = false}) async {
    final generation = ++_generation;
    if (_disposed) return;
    await _prepareSession();
    if (_disposed || generation != _generation) return;
    await _player.setLoopMode(loop ? ja.LoopMode.one : ja.LoopMode.off);
    await _player.setAsset('assets/$path');
    if (_disposed || generation != _generation) return;
    // just_audio play completes only when playback stops. SoundBoard starts
    // clips immediately and owns sequence timing, so don't await that Future.
    unawaited(_player.play().catchError((Object _) {}));
  }

  @override
  Future<void> stop() async {
    _generation++;
    if (!_disposed) await _player.stop();
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _generation++;
    await _player.dispose();
    // Never setActive(false) here: another clip or LiveKit may own audio.
  }
}

Future<void> prepareIdleSoundSession() async {
  if (kIsWeb || defaultTargetPlatform != TargetPlatform.iOS) return;
  // Native engine state, not UI mic flags: receiving audio also owns a session.
  // ignore: experimental_member_use
  final state = AudioManager.instance.audioEngineState;
  if (state.isPlayoutEnabled ||
      state.isRecordingEnabled ||
      GameAudioPolicy.shared.captureRequested) {
    return;
  }
  final session = await AudioSession.instance;
  // Re-check after the asynchronous lookup; the RTC engine may have started.
  // ignore: experimental_member_use
  final latest = AudioManager.instance.audioEngineState;
  if (latest.isPlayoutEnabled ||
      latest.isRecordingEnabled ||
      GameAudioPolicy.shared.captureRequested) {
    return;
  }
  await session.configure(
    const AudioSessionConfiguration(
      avAudioSessionCategory: AVAudioSessionCategory.playback,
      avAudioSessionCategoryOptions:
          AVAudioSessionCategoryOptions.mixWithOthers,
      avAudioSessionMode: AVAudioSessionMode.spokenAudio,
    ),
  );
  // No automatic deactivation on a clip ending. LiveKit remains responsible
  // for its own engine lifecycle. Native interleaving still needs device tests.
  await session.setActive(true);
}
