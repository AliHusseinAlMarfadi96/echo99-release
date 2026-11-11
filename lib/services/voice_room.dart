import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:livekit_client/livekit_client.dart';
import 'package:permission_handler/permission_handler.dart';

import '../livekit_token.dart';
import 'audio_policy.dart';

/// Twitter Spaces-style voice: join as Listener (mic OFF). Mic is toggled
/// explicitly. Screen-recording audio support still requires device testing.
///
/// Host mute (`Seat.micMuted` / board mutedMics): local unmute is blocked and
/// remote audio tracks for that identity stay disabled until the host clears.
enum VoiceLinkState { disconnected, listener, speaking, speakingMuted }

class VoiceRoom {
  /// Secure server-issued voice tokens: prepared, off by default.
  ///
  /// Enable with `--dart-define=VOICE_TOKEN_SERVER=true` AFTER the Cloud
  /// Functions in `functions/` (mintVoiceToken / moderateVoiceParticipant)
  /// are deployed and [serverTokenCall] is bound to
  /// FirebaseFunctions.instance.httpsCallable('mintVoiceToken'). Server
  /// mode deliberately has NO fallback to the bundled LIVEKIT_API_SECRET
  /// path: that legacy path ships the signing secret inside every installed
  /// APK and is kept only until server mode ships, then deleted.
  static const bool _useServerTokens = bool.fromEnvironment(
    'VOICE_TOKEN_SERVER',
  );

  /// Injected server token callable (room name in, signed token out).
  /// Unbound until server mode is activated; server joins fail closed.
  Future<String> Function(String roomName)? serverTokenCall;

  bool inConversation = false;
  Future<void> joinConversation() async {
    inConversation = true;
  }

  Future<void> leaveConversation() async {
    inConversation = false;
  }

  Room? _room;
  String? _tableId;
  EventsListener<RoomEvent>? _events;
  int _micRequest = 0;
  bool micOn = false;
  bool sharingAudio = false;
  void Function()? onPeerLost;

  /// Identities currently host-muted (from Firestore seat flags).
  Set<String> _hostMuted = {};

  /// Server revoked our publish grant (moderateVoiceParticipant).
  bool _serverMuted = false;

  /// Local identity — unmute rejected while listed in [_hostMuted].
  String? _identity;

  bool get connected =>
      _room != null && _room!.connectionState == ConnectionState.connected;

  bool get hostMutedLocal =>
      _identity != null && _hostMuted.contains(_identity);

  /// Identities actually in the LiveKit room right now (the authoritative
  /// voice roster; a client's Firestore `present` flag is forgeable and
  /// crash-stale, so it is never used for this).
  final StreamController<List<String>> _roster =
      StreamController<List<String>>.broadcast();
  Stream<List<String>> get remoteRoster => _roster.stream;

  void _emitRoster() {
    final room = _room;
    if (room == null) {
      _roster.add(const []);
      return;
    }
    _roster.add([
      for (final participant in room.remoteParticipants.values)
        participant.identity,
    ]);
  }

  static const unconfigured = 'خدمة الصوت غير مهيأة حالياً.';

  static const serverUnconfigured = 'الصوت غير متاح حالياً.';

  static const hostMutedError = 'المضيف كتم ميكروفونك';

  @protected
  Future<String?> connectVoice({
    required String identity,
    required String displayName,
    required String tableId,
  }) async {
    _identity = identity;
    if (_room != null &&
        _tableId == tableId &&
        _room!.connectionState == ConnectionState.connected) {
      await _applyRemoteMutes();
      return null;
    }
    String? token;
    if (_useServerTokens) {
      final call = serverTokenCall;
      if (call == null) {
        return serverUnconfigured;
      }
      try {
        token = await call(tableId);
      } catch (_) {
        return serverUnconfigured;
      }
    } else {
      token = mintConfiguredToken(
        identity: identity,
        displayName: displayName,
        room: tableId,
      );
    }
    if (token == null) {
      return unconfigured;
    }
    await _room?.disconnect();
    await _room?.dispose();
    final room = Room();
    _room = room;
    _tableId = tableId;
    await room.connect(LiveKitConfig.url, token);
    // Listener by default: never auto-publish the microphone.
    await room.localParticipant?.setMicrophoneEnabled(false);
    micOn = false;
    GameAudioPolicy.shared.captureRequested = false;
    _serverMuted = !(room.localParticipant?.permissions.canPublish ?? false);
    _watch(room);
    await _applyRemoteMutes();
    _emitRoster();
    return null;
  }

  void _watch(Room room) {
    final previous = _events;
    _events = room.createListener()
      ..on<ParticipantDisconnectedEvent>((_) {
        _emitRoster();
        if (_tableId != null && _tableId != 'echo99lobby') {
          onPeerLost?.call();
        }
      })
      ..on<TrackSubscribedEvent>((event) {
        unawaited(_applyRemoteMutes());
      })
      ..on<ParticipantConnectedEvent>((_) {
        unawaited(_applyRemoteMutes());
        _emitRoster();
      })
      ..on<ParticipantPermissionsUpdatedEvent>((event) {
        // Server-side moderation changed our grants. LiveKit auto-refreshes
        // the token of a connected client, so this is the authoritative
        // signal; the 10-minute token TTL only bounds rejoins.
        final muted = !event.permissions.canPublish;
        if (muted != _serverMuted) {
          _serverMuted = muted;
          if (muted && micOn) {
            unawaited(_room?.localParticipant?.setMicrophoneEnabled(false));
            micOn = false;
            GameAudioPolicy.shared.captureRequested = false;
          }
        }
      });
    previous?.dispose();
  }

  /// Sync host-mute flags from Firestore seats. Disables remote audio for
  /// muted identities and forces local mic off when we are muted.
  Future<void> applyHostMutes(Set<String> mutedIds) async {
    _hostMuted = {...mutedIds};
    if (hostMutedLocal && micOn) {
      await _room?.localParticipant?.setMicrophoneEnabled(false);
      micOn = false;
      GameAudioPolicy.shared.captureRequested = false;
    }
    await _applyRemoteMutes();
  }

  Future<void> _applyRemoteMutes() async {
    final room = _room;
    if (room == null) return;
    for (final participant in room.remoteParticipants.values) {
      final muted = _hostMuted.contains(participant.identity);
      for (final pub in participant.audioTrackPublications) {
        try {
          if (muted) {
            await pub.disable();
          } else {
            await pub.enable();
          }
        } catch (_) {}
      }
    }
  }

  /// Joins a lobby room without opening the microphone.
  Future<String?> warmup({
    required String identity,
    required String displayName,
  }) {
    return connectVoice(
      identity: identity,
      displayName: displayName,
      tableId: 'echo99lobby',
    );
  }

  /// Listener first; auto-publishing requires a saved opt-in. OS permission
  /// and both host flags and server grants are checked before publishing.
  Future<String?> joinAsListener({
    required String identity,
    required String displayName,
    required String tableId,
    bool autoEnableMic = false,
  }) async {
    final request = _micRequest;
    final error = await connectVoice(
      identity: identity,
      displayName: displayName,
      tableId: tableId,
    );
    if (error != null) return error;
    if (!autoEnableMic || request != _micRequest) return null;
    return setMicrophone(
      enabled: true,
      identity: identity,
      displayName: displayName,
      tableId: tableId,
    );
  }

  @protected
  bool get serverAllowsPublish =>
      !_serverMuted &&
      (_room?.localParticipant?.permissions.canPublish ?? false);

  @protected
  Future<bool> requestMicrophonePermission() async =>
      kIsWeb || (await Permission.microphone.request()).isGranted;

  @protected
  Future<void> publishMicrophone(bool enabled) async {
    final local = _room?.localParticipant;
    if (local == null) throw StateError('Voice disconnected');
    await local.setMicrophoneEnabled(enabled);
  }

  @protected
  Future<void> removeMicrophonePublication() async {
    final local = _room?.localParticipant;
    final pub = local?.getTrackPublicationBySource(TrackSource.microphone);
    if (pub != null) await local!.removePublishedTrack(pub.sid);
  }

  /// Unpublish the microphone, but stay in the same room and table.
  /// Muting keeps the publication; this action removes it.
  Future<String?> returnToListener() async {
    _micRequest++;
    try {
      await publishMicrophone(false);
      micOn = false;
      GameAudioPolicy.shared.captureRequested = false;
      await removeMicrophonePublication();
      inConversation = false;
      return null;
    } catch (_) {
      return 'تعذر الرجوع لوضع الاستماع.';
    }
  }

  static VoiceLinkState resolveLinkState({
    required bool connected,
    required bool hasMicPublication,
    required bool micOn,
  }) {
    if (!connected) return VoiceLinkState.disconnected;
    if (!hasMicPublication) return VoiceLinkState.listener;
    return micOn ? VoiceLinkState.speaking : VoiceLinkState.speakingMuted;
  }

  VoiceLinkState get linkState => resolveLinkState(
    connected: connected,
    hasMicPublication:
        _room?.localParticipant?.getTrackPublicationBySource(
          TrackSource.microphone,
        ) !=
        null,
    micOn: micOn,
  );

  Future<String?> setMicrophone({
    required bool enabled,
    required String identity,
    required String displayName,
    required String tableId,
  }) async {
    final request = ++_micRequest;
    try {
      if (enabled && (_hostMuted.contains(identity) || _serverMuted)) {
        return hostMutedError;
      }
      final error = await connectVoice(
        identity: identity,
        displayName: displayName,
        tableId: tableId,
      );
      if (error != null) {
        return error;
      }
      if (enabled && (!serverAllowsPublish || _hostMuted.contains(identity))) {
        return hostMutedError;
      }
      if (request != _micRequest) return 'أُلغي تشغيل الميكروفون.';
      if (enabled && !await requestMicrophonePermission()) {
        return 'لم يُمنح إذن الميكروفون.';
      }
      if (request != _micRequest) return 'أُلغي تشغيل الميكروفون.';
      // Permission UI may have been open while the host/server muted us.
      if (enabled && (!serverAllowsPublish || _hostMuted.contains(identity))) {
        return hostMutedError;
      }
      final previousIntent = GameAudioPolicy.shared.captureRequested;
      GameAudioPolicy.shared.captureRequested = enabled;
      try {
        await publishMicrophone(enabled);
      } catch (_) {
        GameAudioPolicy.shared.captureRequested = previousIntent;
        rethrow;
      }
      if (request != _micRequest) {
        await publishMicrophone(false);
        GameAudioPolicy.shared.captureRequested = false;
        micOn = false;
        return 'أُلغي تشغيل الميكروفون.';
      }
      micOn = enabled;
      if (enabled) inConversation = true;
      return null;
    } catch (_) {
      return 'تعذر الاتصال الصوتي.';
    }
  }

  Future<String?> setShareDeviceAudio({
    required bool enabled,
    required String identity,
    required String displayName,
    required String tableId,
  }) async {
    try {
      final error = await connectVoice(
        identity: identity,
        displayName: displayName,
        tableId: tableId,
      );
      if (error != null) {
        return error;
      }
      await AudioManager.instance.setSpeakerOutputPreferred(
        enabled,
        force: enabled,
      );
      sharingAudio = enabled;
      return null;
    } catch (_) {
      return 'تعذر مشاركة صوت الجهاز.';
    }
  }

  Future<void> close() async {
    _micRequest++;
    GameAudioPolicy.shared.captureRequested = false;
    onPeerLost = null;
    try {
      await _events?.dispose();
    } catch (_) {}
    _events = null;
    try {
      await _room?.disconnect();
      await _room?.dispose();
    } catch (_) {}
    _room = null;
    _tableId = null;
    _identity = null;
    _hostMuted = {};
    _serverMuted = false;
    micOn = false;
    sharingAudio = false;
    _emitRoster();
  }
}
