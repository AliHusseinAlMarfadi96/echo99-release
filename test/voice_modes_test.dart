import 'dart:async';

import 'package:echo99/services/voice_room.dart';
import 'package:echo99/services/settings_model.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class FakeVoice extends VoiceRoom {
  bool allow = true;
  bool permission = true;
  int permissionRequests = 0;
  int connects = 0;
  int removals = 0;
  bool removalFails = false;
  Future<void> Function()? onConnect;
  final publishes = <bool>[];
  Future<void> Function()? onPermission;
  @override
  Future<String?> connectVoice({
    required String identity,
    required String displayName,
    required String tableId,
  }) async {
    connects++;
    await onConnect?.call();
    return null;
  }

  @override
  bool get serverAllowsPublish => allow;
  @override
  Future<bool> requestMicrophonePermission() async {
    permissionRequests++;
    await onPermission?.call();
    return permission;
  }

  @override
  Future<void> publishMicrophone(bool enabled) async {
    publishes.add(enabled);
  }

  @override
  Future<void> removeMicrophonePublication() async {
    removals++;
    if (removalFails) throw StateError('unpublish failed');
  }
}

Future<String?> join(FakeVoice v, {bool auto = false}) => v.joinAsListener(
  identity: 'me',
  displayName: 'لاعب',
  tableId: 't',
  autoEnableMic: auto,
);
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'auto mic is off by default, persisted only after explicit change',
    () async {
      SharedPreferences.setMockInitialValues({});
      final settings = await SettingsModel.load();
      expect(settings.autoMicOnJoin, false);
      await settings.setAutoMicOnJoin(true);
      expect((await SettingsModel.load()).autoMicOnJoin, true);
      await settings.setAutoMicOnJoin(false);
      expect((await SettingsModel.load()).autoMicOnJoin, false);
    },
  );
  test(
    'listener entry neither requests mic permission nor publishes',
    () async {
      final v = FakeVoice();
      expect(await join(v), null);
      expect(v.permissionRequests, 0);
      expect(v.publishes, isEmpty);
    },
  );
  test('opt in requires OS permission before publish', () async {
    final v = FakeVoice();
    expect(await join(v, auto: true), null);
    expect(v.permissionRequests, 1);
    expect(v.publishes, [true]);
    expect(v.inConversation, true);
  });
  test('denied permission never publishes or marks mic on', () async {
    final v = FakeVoice()..permission = false;
    expect(await join(v, auto: true), isNotNull);
    expect(v.publishes, isEmpty);
    expect(v.micOn, false);
  });
  test('initial host mute blocks opted-in auto publish', () async {
    final v = FakeVoice();
    await v.applyHostMutes({'me'});
    expect(await join(v, auto: true), VoiceRoom.hostMutedError);
    expect(v.permissionRequests, 0);
    expect(v.publishes, isEmpty);
  });
  test('initial server grant blocks opted-in auto publish', () async {
    final v = FakeVoice()..allow = false;
    expect(await join(v, auto: true), VoiceRoom.hostMutedError);
    expect(v.permissionRequests, 0);
    expect(v.publishes, isEmpty);
  });
  test(
    'host mute received during OS permission prompt blocks publish',
    () async {
      final v = FakeVoice();
      v.onPermission = () => v.applyHostMutes({'me'});
      expect(await join(v, auto: true), VoiceRoom.hostMutedError);
      expect(v.publishes, isEmpty);
    },
  );
  test(
    'server revocation during OS permission prompt blocks publish',
    () async {
      final v = FakeVoice();
      v.onPermission = () async {
        v.allow = false;
      };
      expect(await join(v, auto: true), VoiceRoom.hostMutedError);
      expect(v.publishes, isEmpty);
    },
  );
  test(
    'mute retains publication, return listener removes it without reconnect',
    () async {
      final v = FakeVoice();
      await join(v, auto: true);
      await v.setMicrophone(
        enabled: false,
        identity: 'me',
        displayName: 'لاعب',
        tableId: 't',
      );
      expect(v.removals, 0);
      expect(v.inConversation, true);
      final connections = v.connects;
      expect(await v.returnToListener(), null);
      expect(v.removals, 1);
      expect(v.connects, connections);
      expect(v.inConversation, false);
      expect(v.micOn, false);
    },
  );
  test('manual disable cancels an in-flight permission request', () async {
    final v = FakeVoice();
    final entered = Completer<void>();
    final release = Completer<void>();
    v.onPermission = () async {
      entered.complete();
      await release.future;
    };
    final start = join(v, auto: true);
    await entered.future;
    await v.setMicrophone(
      enabled: false,
      identity: 'me',
      displayName: 'لاعب',
      tableId: 't',
    );
    release.complete();
    expect(await start, isNotNull);
    expect(v.publishes, [false]);
    expect(v.micOn, false);
  });
  test(
    'manual disable during initial connect cancels opted-in publish',
    () async {
      final v = FakeVoice();
      final entered = Completer<void>();
      final release = Completer<void>();
      var first = true;
      v.onConnect = () async {
        if (first) {
          first = false;
          entered.complete();
          await release.future;
        }
      };
      final start = join(v, auto: true);
      await entered.future;
      await v.setMicrophone(
        enabled: false,
        identity: 'me',
        displayName: 'لاعب',
        tableId: 't',
      );
      release.complete();
      expect(await start, null);
      expect(v.publishes, [false]);
      expect(v.permissionRequests, 0);
    },
  );
  test('server denial observed on reconnect prevents publish', () async {
    final v = FakeVoice();
    v.onConnect = () async {
      v.allow = false;
    };
    expect(await join(v, auto: true), VoiceRoom.hostMutedError);
    expect(v.publishes, isEmpty);
  });
  test('listener return failure leaves mic off but does not claim listener success', () async {
    final v = FakeVoice();
    await join(v, auto: true);
    v.removalFails = true;
    expect(await v.returnToListener(), isNotNull);
    expect(v.micOn, false);
    expect(v.inConversation, true);
    // No assertion about the actual iOS category: requires a device.
  });
  test('publication based states do not claim audio-session category', () {
    VoiceLinkState state(bool connected, bool pub, bool mic) =>
        VoiceRoom.resolveLinkState(
          connected: connected,
          hasMicPublication: pub,
          micOn: mic,
        );
    expect(state(false, false, false), VoiceLinkState.disconnected);
    expect(state(true, false, false), VoiceLinkState.listener);
    expect(state(true, true, true), VoiceLinkState.speaking);
    expect(state(true, true, false), VoiceLinkState.speakingMuted);
  });
}
