import 'dart:async';

import 'package:echo99/services/speech.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'dart:io';

import 'package:echo99/app_version.dart';
import 'package:echo99/game/engine.dart';
import 'package:echo99/game/jackaroo.dart';
import 'package:echo99/services/game_presentation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'ordered iOS narration waits for native callback and cancellation',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final finished = Completer<void>();
      var cancelled = false;
      const channel = MethodChannel('echo99/speech_completion');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            if (call.method == 'announce') await finished.future;
            if (call.method == 'cancel') {
              cancelled = true;
              finished.complete();
            }
            return null;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );
      final speech = Speech();
      var complete = false;
      final pending = speech.ordered('result', useInternalTts: false).then((_) {
        complete = true;
      });
      await Future<void>.delayed(Duration.zero);
      expect(complete, false);
      await speech.cancelOrdered();
      await pending;
      expect(cancelled, true);
      expect(complete, true);
    },
  );

  test('red and green keep one distinct forward and backward timbre', () {
    expect(jackarooStepSounds(4, colorIndex: 0), List.filled(4, 'jk_step1'));
    expect(jackarooStepSounds(4, colorIndex: 2), List.filled(4, 'jk_step2'));
    expect(
      jackarooStepSounds(-4, colorIndex: 0),
      List.filled(4, 'jk_step_back1'),
    );
    expect(
      jackarooStepSounds(-4, colorIndex: 2),
      List.filled(4, 'jk_step_back2'),
    );
    for (var c = 0; c < 4; c++) {
      expect(jackarooStepSounds(-4, colorIndex: c).toSet(), hasLength(1));
    }
  });
  test('king capture cues occur at each actual path square and each stone', () {
    final board = JackarooBoard(
      mode: jackarooComplex,
      colors: {'a': 0, 'b': 2},
      pieces: {
        'a': [5, jackarooHome, jackarooHome, jackarooHome],
        'b': [46, 49, jackarooHome, jackarooHome],
      },
    );
    // Green base38 +46 wraps to8, +49 wraps to11. Path5..18 captures8,11.
    final step = jackarooAdvance(board, 'a', 0, 13, kingSweep: true)!;
    expect(step.kills, [('b', 0), ('b', 1)]);
    expect(step.sounds.where((s) => s == 'jk_step1'), hasLength(13));
    expect(step.sounds.where((s) => s == 'jk_kill'), hasLength(2));
    expect(step.sounds.indexOf('jk_kill'), 3); // after pulse for square8
    expect(step.board.pieces['b']!.take(2), [jackarooHome, jackarooHome]);
  });
  test('installed version label and update comparison match pubspec', () {
    expect(
      File('pubspec.yaml').readAsStringSync(),
      contains('version: $appVersion+$appBuild'),
    );
    expect(
      File('lib/screens/settings_screen.dart').readAsStringSync(),
      isNot(contains('1.3.3 (18)')),
    );
  });
  test('snakes winner cue and presentation include one celebration only', () {
    final before = newWaitingTable(
      id: 't',
      name: 't',
      hostId: 'a',
      hostName: 'a',
      settings: const TableSettings(startPoints: 10, timerSeconds: 0),
      game: gameSnakes,
    );
    final after = MatchState.fromMap({
      ...before.toMap(),
      'status': 'finished',
      'winnerId': 'a',
      'cue': {
        'type': 'snakes',
        'nonce': 1,
        'also': ['snakes/step', 'applause'],
      },
      'players': [
        {'id': 'a', 'name': 'a', 'points': 1, 'isBot': false},
        {'id': 'b', 'name': 'b', 'points': 0, 'isBot': true},
      ],
    }, 't');
    expect(presentationClips(before, after, 'a'), ['snakes/step', 'applause']);
    expect(presentationClips(before, after, 'b'), ['snakes/step', 'loss2']);
  });
}
