import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:livekit_client/livekit_client.dart';
import 'package:permission_handler/permission_handler.dart';

import '../livekit_token.dart';

/// Twitter Spaces-style voice: join as Listener (mic OFF). Mic is toggled
/// explicitly. When mic is off, no local audio is published — screen-recording
/// friendly.
///
/// Host mute (`Seat.micMuted` / board mutedMics): local unmute is blocked and
/// remote audio tracks for that identity stay disabled until the host clears.
class VoiceRoom {
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
  bool micOn = false;
  bool sharingAudio = false;
  void Function()? onPeerLost;

  /// Identities currently host-muted (from Firestore seat flags).
  Set<String> _hostMuted = {};

  /// Local identity — unmute rejected while listed in [_hostMuted].
  String? _identity;

  bool get connected =>
      _room != null && _room!.connectionState == ConnectionState.connected;

  bool get hostMutedLocal =>
      _identity != null && _hostMuted.contains(_identity);

  static const unconfigured =
      'الصوت غير مهيأ. مرّر LIVEKIT_API_SECRET عند البناء.';

  static const hostMutedError = 'المضيف كتم ميكروفونك';

  Future<String?> _connect({
    required String identity,
    required String displayName,
    required String tableId,
  }) async {
    final token = mintConfiguredToken(
      identity: identity,
      displayName: displayName,
      room: tableId,
    );
    if (token == null) {
      return unconfigured;
    }
    _identity = identity;
    if (_room != null &&
        _tableId == tableId &&
        _room!.connectionState == ConnectionState.connected) {
      await _applyRemoteMutes();
      return null;
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
    _watch(room);
    await _applyRemoteMutes();
    return null;
  }

  void _watch(Room room) {
    final previous = _events;
    _events = room.createListener()
      ..on<ParticipantDisconnectedEvent>((_) {
        if (_tableId != null && _tableId != 'echo99lobby') {
          onPeerLost?.call();
        }
      })
      ..on<TrackSubscribedEvent>((event) {
        unawaited(_applyRemoteMutes());
      })
      ..on<ParticipantConnectedEvent>((_) {
        unawaited(_applyRemoteMutes());
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
    return _connect(
      identity: identity,
      displayName: displayName,
      tableId: 'echo99lobby',
    );
  }

  /// Join a table voice room as Listener (mic OFF). Safe for screen recording.
  Future<String?> joinAsListener({
    required String identity,
    required String displayName,
    required String tableId,
  }) {
    return _connect(
      identity: identity,
      displayName: displayName,
      tableId: tableId,
    );
  }

  Future<String?> setMicrophone({
    required bool enabled,
    required String identity,
    required String displayName,
    required String tableId,
  }) async {
    try {
      if (enabled && _hostMuted.contains(identity)) {
        return hostMutedError;
      }
      final error = await _connect(
        identity: identity,
        displayName: displayName,
        tableId: tableId,
      );
      if (error != null) {
        return error;
      }
      if (enabled && !kIsWeb) {
        final status = await Permission.microphone.request();
        if (!status.isGranted) {
          return 'لم يُمنح إذن الميكروفون.';
        }
      }
      await _room?.localParticipant?.setMicrophoneEnabled(enabled);
      micOn = enabled;
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
      final error = await _connect(
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
    micOn = false;
    sharingAudio = false;
  }
}

