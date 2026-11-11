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
abstract class SequenceSoundPlayer implements SoundPlayer {
  Future<void> playAssets(List<String> paths);
}

/// Uniform ~353 BPM movement cadence (170ms start-to-start across all
/// colors), matched to the user's TableEx reference recordings (measured
/// step-to-step median 170ms).
const Duration kStepBeatInterval = Duration(milliseconds: 170);

/// Where a step clip's tail is cut. just_audio's play() future completes
/// only when playback completes (verified in just_audio 0.10.6 docs), and
/// the completion signal plus the following pause/seek cross the platform
/// channel, so a clip that runs the full beat would start the next step
/// late and drag that color off the shared grid. All four step assets end
/// their audible content by ~80ms (long clips by ~45ms, measured on
/// decoded PCM, 5ms windows, -45dB threshold), so cutting at 140ms keeps
/// every audible sample while leaving ~30ms of silent headroom for the
/// completion + IPC round trip before the next 170ms beat. For clips
/// shorter than this the clip is a no-op.
const Duration kStepClipEnd = Duration(milliseconds: 140);

bool isStepAssetPath(String path) =>
    path == 'sounds/jk_step1.mp3' ||
    path == 'sounds/jk_step2.mp3' ||
    path == 'sounds/jk_step_back1.mp3' ||
    path == 'sounds/jk_step_back2.mp3';

/// Minimal playback surface the paced step run needs. The default
/// implementation delegates to just_audio; tests substitute a fake so the
/// production pacing logic runs without platform channels.
abstract class StepClipDriver {
  Future<void> pause();

  /// Loads [asset], optionally clipping its tail at [clipEnd]. Step clips
  /// are clipped to the beat window: jk_step1's audible click ends within
  /// ~50ms and the rest of its 216ms container is digital silence
  /// (measured), so clipping keeps the cadence uniform across colors
  /// without cutting audible sound.
  Future<void> setClip(String asset, {Duration? clipEnd});
  Future<void> seek(Duration position);
  Future<void> play();
}

/// Plays identical movement clips at the [kStepBeatInterval] cadence
/// (start-to-start) from the original asset at natural 1.0x speed, with the
/// tail clipped at the beat window (see [StepClipDriver.setClip]).
/// Extracted from ManagedSoundPlayer so the cadence is unit-testable.
class PacedStepRunner {
  factory PacedStepRunner({
    required StepClipDriver driver,
    Stopwatch Function()? stopwatchFactory,
    Future<void> Function(Duration)? delay,
  }) =>
      PacedStepRunner._(
        driver,
        stopwatchFactory ?? Stopwatch.new,
        delay ?? Future<void>.delayed,
      );
  PacedStepRunner._(this._driver, this._stopwatchFactory, this._delay);

  final StepClipDriver _driver;
  final Stopwatch Function() _stopwatchFactory;
  final Future<void> Function(Duration) _delay;

  /// Runs [stepCount] paced plays of [assetPath]. [cancelled] is checked
  /// before every action; when it reports true the run aborts immediately.
  Future<void> run({
    required String assetPath,
    required int stepCount,
    required bool Function() cancelled,
  }) async {
    await _driver.pause();
    if (cancelled()) return;
    await _driver.setClip(
      'assets/$assetPath',
      clipEnd: kStepClipEnd,
    );
    if (cancelled()) return;

    final watch = _stopwatchFactory()..start();
    for (var step = 0; step < stepCount; step++) {
      if (cancelled()) return;
      final targetStart = kStepBeatInterval * step;
      final waitBeforeStep = targetStart - watch.elapsed;
      if (waitBeforeStep > Duration.zero) {
        await _delay(waitBeforeStep);
        if (cancelled()) return;
      }
      if (step > 0) {
        await _driver.pause();
        await _driver.seek(Duration.zero);
        if (cancelled()) return;
      }
      await _driver.play();
    }

    final totalRunWindow = kStepBeatInterval * stepCount;
    final tailWait = totalRunWindow - watch.elapsed;
    if (tailWait > Duration.zero && !cancelled()) {
      await _delay(tailWait);
    }
  }
}

class _JaStepClipDriver implements StepClipDriver {
  const _JaStepClipDriver(this._player);
  final ja.AudioPlayer _player;
  @override
  Future<void> pause() => _player.pause();
  @override
  Future<void> setClip(String asset, {Duration? clipEnd}) =>
      _player.setAudioSource(
        clipEnd == null
            ? ja.AudioSource.asset(asset)
            : ja.ClippingAudioSource(
                child: ja.AudioSource.asset(asset),
                start: Duration.zero,
                end: clipEnd,
              ),
      );
  @override
  Future<void> seek(Duration position) => _player.seek(position);
  @override
  Future<void> play() => _player.play();
}

class ManagedSoundPlayer implements SequenceSoundPlayer {
  ManagedSoundPlayer({
    Future<void> Function()? prepareSession,
    ja.AudioPlayer? player,
    Stopwatch Function()? stopwatchFactory,
    Future<void> Function(Duration)? delay,
  })  : _prepareSession = prepareSession ?? prepareIdleSoundSession,
        _player = player ??
            ja.AudioPlayer(
              handleAudioSessionActivation: false,
            ),
        _stopwatchFactory = stopwatchFactory ?? Stopwatch.new,
        _delay = delay ?? Future<void>.delayed;
  final Future<void> Function() _prepareSession;
  final ja.AudioPlayer _player;
  final Stopwatch Function() _stopwatchFactory;
  final Future<void> Function(Duration) _delay;
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
      // Native play resolves on playlist completion or stop and propagates
      // playback failures. Do not swallow errors and wait for a false finish.
      await _player.play();
    } catch (error) {
      SoundDiagnostics.record(stage, error);
      rethrow;
    }
  }

  /// Preload one native playlist so short movement beats do not wait for a
  /// separate Dart load/start round trip on every square.
  @override
  Future<void> playAssets(List<String> paths) async {
    final generation = ++_generation;
    if (_disposed || paths.isEmpty) return;
    try {
      await _prepareSession();
      if (_disposed || generation != _generation) return;
      await _player.setLoopMode(ja.LoopMode.off);
      SoundDiagnostics.lastFailure.value = null;

      var index = 0;
      while (index < paths.length) {
        if (_disposed || generation != _generation) return;
        final current = paths[index];

        if (isStepAssetPath(current)) {
          var runEnd = index + 1;
          while (runEnd < paths.length && paths[runEnd] == current) {
            runEnd++;
          }
          await _playPacedStepRun(
            assetPath: current,
            stepCount: runEnd - index,
            generation: generation,
          );
          index = runEnd;
        } else {
          var runEnd = index + 1;
          while (runEnd < paths.length && !isStepAssetPath(paths[runEnd])) {
            runEnd++;
          }
          await _player.pause();
          if (_disposed || generation != _generation) return;
          await _player.setAudioSources([
            for (final path in paths.sublist(index, runEnd))
              if (path == 'sounds/jk_burn_cards.mp3')
                ja.ClippingAudioSource(
                  child: ja.AudioSource.asset('assets/$path'),
                  start: Duration.zero,
                  end: const Duration(milliseconds: 752),
                )
              else
                ja.AudioSource.asset('assets/$path'),
          ]);
          if (_disposed || generation != _generation) return;
          await _player.play();
          index = runEnd;
        }
      }
    } catch (error) {
      SoundDiagnostics.record('asset-load', error);
      rethrow;
    }
  }

  /// Plays [stepCount] identical movement clips at the [kStepBeatInterval]
  /// cadence via [PacedStepRunner]; see that class for the cadence contract.
  Future<void> _playPacedStepRun({
    required String assetPath,
    required int stepCount,
    required int generation,
  }) {
    return PacedStepRunner(
      driver: _JaStepClipDriver(_player),
      stopwatchFactory: _stopwatchFactory,
      delay: _delay,
    ).run(
      assetPath: assetPath,
      stepCount: stepCount,
      cancelled: () => _disposed || generation != _generation,
    );
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
