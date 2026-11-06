import 'package:echo99/services/audio_policy.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter_test/flutter_test.dart';
void main() {
  test('listener media, pending capture, native capture and asynchronous mute', () {
    var recording = false;
    final policy = GameAudioPolicy(nativeRecording: () => recording);
    expect(policy.soundContext.iOS.category, AVAudioSessionCategory.playback);
    policy.captureRequested = true;
    expect(policy.soundContext.iOS.category, AVAudioSessionCategory.playAndRecord);
    recording = true;
    policy.captureRequested = false; // Native stop has not completed yet.
    expect(policy.needsInput, true);
    expect(policy.soundContext.iOS.category, AVAudioSessionCategory.playAndRecord);
    recording = false;
    expect(policy.soundContext.iOS.category, AVAudioSessionCategory.playback);
    expect(policy.soundContext.iOS.options, contains(AVAudioSessionOptions.mixWithOthers));
  });
  test('native reconnect capture wins over stale local mic-off flag', () {
    var recording = false;
    final policy = GameAudioPolicy(nativeRecording: () => recording);
    expect(policy.needsInput, false);
    recording = true;
    expect(policy.needsInput, true);
    recording = false;
    expect(policy.needsInput, false);
  });
}
