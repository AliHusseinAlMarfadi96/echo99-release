import 'dart:async';

import 'audio_policy.dart';

import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart' as ja;
import 'package:livekit_client/livekit_client.dart';

class SoundDiagnostics {
  static final lastFailure = ValueNotifier<String?>(null);
  static void record(String stage, Object error) {
    final code = error is ja.PlayerException
        ? error.code.toString()
        : error.runtimeType.toString();
    // Only a controlled stage and exception code/class. Never raw messages.
    lastFailure.value = '$stage:$code';
  }
}

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
    var stage = 'session';
    try {
      await _prepareSession();
      if (_disposed || generation != _generation) return;
      stage = 'loop';
      await _player.setLoopMode(loop ? ja.LoopMode.one : ja.LoopMode.off);
      stage = 'asset-load';
      await _player.setAsset('assets/$path');
      if (_disposed || generation != _generation) return;
      stage = 'play';
      SoundDiagnostics.lastFailure.value = null;
      // play completes on stop/end, not at playback start.
      unawaited(
        _player.play().catchError((Object error) {
          if (!_disposed && generation == _generation) {
            SoundDiagnostics.record('play', error);
          }
        }),
      );
    } catch (error) {
      SoundDiagnostics.record(stage, error);
      rethrow;
    }
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
  if (!await session.setActive(true)) {
    throw StateError('Audio session activation refused');
  }
}
