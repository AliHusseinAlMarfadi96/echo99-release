import 'dart:async';
import 'dart:math';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';

import '../echo_scope.dart';
import '../game/engine.dart';
import '../game/jackaroo.dart';
import '../game/lifecycle.dart';
import '../game/rules.dart';
import '../game/snakes.dart';
import '../game/ludo.dart';
import '../game/thousand_miles.dart';
import '../services/doc_id.dart';
import '../services/local_match.dart';
import '../services/presence.dart';
import '../services/social_repository.dart';
import '../services/sounds.dart';
import '../services/table_repository.dart';
import '../services/table_event_audio.dart';
import '../services/game_presentation.dart';
import '../services/table_service.dart';
import '../services/voice_authority.dart';
import '../services/voice_room.dart';
import '../widgets/game_gestures.dart';
import '../widgets/mic_pad.dart';
import '../widgets/playing_card.dart';
import '../widgets/profile_dialog.dart';
import '../widgets/table_settings_form.dart';

/// Announcement every client hears when the host starts with new settings.
String settingsAnnouncement(MatchState state) {
  final timer = state.timerSeconds >= minTimerSeconds ? state.timerSeconds : 0;
  switch (state.game) {
    case gameJackaroo:
      final mode = state.board['mode'] == jackarooComplex
          ? 'الكومبلكس'
          : 'عادي';
      return 'إعدادات الطاولة — الوضع: $mode، مؤقت الدور: $timer';
    case gameSnakes:
      return 'إعدادات الطاولة — مؤقت الدور: $timer';
    case gameLudo:
      final mode = state.board['ludoMode'] == ludoModeFree ? 'حر' : 'عادي';
      return 'إعدادات الطاولة — اللودو: $mode، مؤقت الدور: $timer';
    case gameThousandMiles:
      return 'إعدادات الطاولة — حد النقاط: ${state.maxPoints}، مؤقت الدور: $timer';
    default:
      return 'إعدادات الطاولة — أقصى نقاط: ${state.maxPoints}، مؤقت الدور: $timer';
  }
}

/// Accessible table for Echo99, Jackaroo, and Snakes and Ladders.
///
/// VoiceOver / TalkBack: focus the table, then the Actions rotor / custom
/// actions menu: إعلان الدور، (المجموع | مواقع القطع | موقعي، مواقع جميع
/// اللاعبين)، فتح السجل. Mic gestures live ONLY on the mic pad.
class TableScreen extends StatefulWidget {
  const TableScreen({
    super.key,
    required this.tableId,
    this.offline = false,
    this.initial,
  });

  final String tableId;
  final bool offline;

  /// The waiting offline table from «إنشاء طاولة». Host seat only.
  final MatchState? initial;

  @override
  State<TableScreen> createState() => _TableScreenState();
}

class _TableScreenState extends State<TableScreen> with WidgetsBindingObserver {
  final _localRandom = Random();
  final _chatAudio = TableChatAudio();
  Future<void> _presentation = Future<void>.value();
  bool _presenting = false;
  bool _presentationPaused = false;
  final _chatController = TextEditingController();
  final _privateController = TextEditingController();
  final _logEntries = ValueNotifier<List<TableLogEntry>>(const []);
  final _privateMessages = ValueNotifier<List<PrivateMessage>>(const []);
  final List<PrivateMessage> _sentPrivate = [];
  List<PrivateMessage> _receivedPrivate = const [];
  StreamSubscription<MatchState?>? _sub;
  StreamSubscription<List<TableLogEntry>>? _logSub;
  StreamSubscription<List<PrivateMessage>>? _pmSub;
  StreamSubscription<Set<String>>? _seatSub;
  StreamSubscription<String?>? _hostSub;
  StreamSubscription<bool>? _connSub;
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _voiceRoomSub;

  /// Voice-admission cache, fed by [_voiceRoomSub]: null = not loaded yet,
  /// so the first join attempt proceeds and later ones wait for admission.
  bool? _voiceRoomExists;
  bool _voiceMemberOk = false;

  /// Identities with a ban tombstone in the voice room: every honest client
  /// disables their audio locally, even while the live-room moderation call
  /// has not landed (host offline / issuer unreachable).
  Set<String> _voiceBanned = {};

  /// Identities actually connected to the LiveKit room (authoritative voice
  /// roster; the client `present` flag is forgeable and crash-stale).
  /// Null until the first roster event arrives.
  List<String>? _voiceRoster;

  /// True when the roster stream errored: the participants list falls back
  /// to a clearly labelled unavailable note instead of pretending to be
  /// complete.
  bool _voiceRosterFailed = false;
  StreamSubscription<List<String>>? _voiceRosterSub;
  Timer? _bot;
  Timer? _clock;
  MatchState? _state;
  List<TableLogEntry> _log = const [];
  final List<TableLogEntry> _localLog = [];
  var _baseline = false;
  var _busy = false;
  var _left = false;
  var _kicked = false;
  var _presenceStarted = false;
  var _selfReconnecting = false;
  final Set<String> _seenSeats = {};
  var _hostSeen = false;
  int? _hostLostAt;
  int? _graceSweepAt;
  int? _botArmed;
  int? _timeoutFired;
  int? _ludoSelected;
  int _lastBeat = 0;
  String? _coupAnnounced;
  int? _coupHandled;
  late EchoScope _scope;

  bool get _online => !widget.offline;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      final scope = EchoScope.of(context);
      scope.voice.onPeerLost = () {
        if (mounted) {
          scope.sounds.play('disconnect');
          _appendSystem('فقد أحد اللاعبين الاتصال');
        }
      };
      scope.sounds.play('join');
      _clock = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
      if (widget.offline) {
        _onState(
          widget.initial ??
              localWaitingTable(
                playerId: scope.settings.playerId,
                playerName: scope.settings.displayName,
                settings: const TableSettings(
                  startPoints: defaultStartPoints,
                  timerSeconds: 0,
                ),
              ),
        );
        return;
      }
      final repo = scope.repo;
      if (repo == null) {
        return;
      }
      repo.rename(
        tableId: widget.tableId,
        playerId: scope.settings.playerId,
        playerName: scope.settings.displayName,
      );
      _sub = repo.watchTable(widget.tableId).listen(_onState);
      // Voice authority (owner's policy): anyone who opens the table joins
      // as a listener - a missing own entry is self-created (rules force it
      // unmuted/unbanned; existing mutes/bans always hold). Speaking stays
      // voluntary via the mic button; the host can mute or ban from voice.
      _voiceRoomSub = scope.voiceAuthority?.watchRoom(widget.tableId).listen((snap) {
            if (!mounted) return;
            _voiceRoomExists = snap.exists;
            final entry = VoiceMember.fromMap(
              snap.data()?['members']?[scope.settings.playerId],
            );
            _voiceMemberOk = entry != null && !entry.banned;
            final members = VoiceAuthority.parseMembers(snap.data());
            _voiceBanned = {
              for (final e in members.entries)
                if (e.value.banned || e.value.muted) e.key,
            };
            unawaited(scope.voice.applyHostMutes(_currentMutedIds()));
            final state = _state;
            if (state == null || scope.voice.connected) return;
            if (entry == null && snap.exists) {
              // Not a member yet: self-join as listener, then connect.
              unawaited(
                scope.voiceAuthority
                    ?.ensureSelfListener(
                      tableId: widget.tableId,
                      uid: scope.settings.playerId,
                    )
                    .then((_) => _joinVoice(state))
                    .onError((_, _) {}),
              );
            } else if (_voiceMemberOk) {
              unawaited(_joinVoice(state));
            }
          }, onError: (_) {});
      _voiceRosterSub = scope.voice.remoteRoster.listen(
        (ids) => setState(() {
          _voiceRoster = ids;
          _voiceRosterFailed = false;
        }),
        onError: (_) => setState(() => _voiceRosterFailed = true),
      );
      _logSub = repo.watchLog(widget.tableId).listen((entries) {
        if (mounted) {
          final clips = _chatAudio.update(entries, me: scope.settings.playerId);
          setState(() => _log = entries);
          _publishLog();
          for (final clip in clips) {
            unawaited(scope.sounds.play(clip));
          }
        }
      });
      final social = scope.social;
      final me = scope.settings.playerId;
      if (social != null && isSafeDocId(me) && !scope.account.guest) {
        _pmSub = social.watchPrivateMessageList(me).listen((list) {
          _receivedPrivate = list;
          _publishPrivate();
        }, onError: (_) {});
      }
      // Keep the process (and LiveKit) alive when locked / minimized.
      unawaited(TableForegroundService.start('Echo99 — طاولة نشطة'));
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _scope = EchoScope.of(context);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _sub?.cancel();
    _logSub?.cancel();
    _pmSub?.cancel();
    _seatSub?.cancel();
    _hostSub?.cancel();
    _connSub?.cancel();
    _voiceRoomSub?.cancel();
    _voiceRosterSub?.cancel();
    if (!widget.offline) {
      unawaited(
        _scope.voiceAuthority
            ?.setPresent(
              tableId: widget.tableId,
              uid: _scope.settings.playerId,
              present: false,
            )
            .onError((_, _) {}),
      );
    }
    _bot?.cancel();
    _clock?.cancel();
    unawaited(_scope.sounds.cancelPresentations());
    unawaited(_scope.speech.cancelOrdered());
    _chatController.dispose();
    _privateController.dispose();
    if (!_left) {
      _onLeave(fromDispose: true);
    }
    _logEntries.dispose();
    _privateMessages.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _presentationPaused = false;
      final current = _state;
      if (current != null) {
        _botArmed = null;
        _armBot(current);
      }
      _onResume();
      return;
    }
    _presentationPaused = true;
    unawaited(_scope.sounds.cancelPresentations());
    unawaited(_scope.speech.cancelOrdered());
    _bot?.cancel();
    // Paused / hidden: stay seated. The foreground service (Android) and
    // UIBackgroundModes audio (iOS) keep LiveKit alive; RTDB presence +
    // the 60 s grace handle a truly dead socket.
    if (state == AppLifecycleState.detached && !_left) {
      _onLeave(fromDispose: true);
    }
  }

  Future<void> _onResume() async {
    if (!mounted || widget.offline || _left || _kicked) {
      return;
    }
    final repo = _scope.repo;
    if (repo == null) {
      return;
    }
    try {
      final snap = await repo.watchTable(widget.tableId).first;
      if (!mounted) {
        return;
      }
      if (snap == null) {
        _kickToMenu('الطاولة أُغلقت');
        return;
      }
      final me = _scope.settings.playerId;
      final seat = snap.players.where((s) => s.id == me).firstOrNull;
      if (seat != null && seat.reconnecting) {
        await repo.markReconnected(tableId: widget.tableId, playerId: me);
      }
      await _scope.presence.joinTable(
        tableId: widget.tableId,
        host: snap.hostId == me,
      );
    } catch (_) {}
  }

  void _kickToMenu(String reason) {
    if (_kicked || !mounted) {
      return;
    }
    _kicked = true;
    _left = true;
    final scope = _scope;
    scope.voice.onPeerLost = null;
    unawaited(scope.voice.close());
    unawaited(scope.presence.leaveTable());
    unawaited(TableForegroundService.stop());
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(reason)));
    Navigator.of(context).popUntil((route) => route.isFirst);
  }

  void _onState(MatchState? next) {
    if (!mounted) {
      return;
    }
    final prev = _state;
    setState(() => _state = next);
    if (next == null) {
      if (_baseline && !_left) {
        _kickToMenu('الطاولة أُغلقت');
      }
      return;
    }
    if (!_baseline) {
      _baseline = true;
      _startPresence(next);
      if (!widget.offline) unawaited(_joinVoice(next));
      _armBot(next);
      return;
    }
    _presenting = true;
    _bot?.cancel();
    _botArmed = null;
    final pending = _scope.sounds.present(() async {
      if (!mounted || _presentationPaused) return;
      await _react(prev, next);
    });
    _presentation = pending;
    unawaited(
      pending
          .catchError((Object error) {
            // Playback failure is reported, not silently presented as completed.
            if (mounted && error is! PresentationCancelled) {
              _say('تعذر إكمال صوت الحركة. راجع اختبار الصوت في الإعدادات.');
            }
          })
          .whenComplete(() {
            if (!mounted || !identical(_presentation, pending)) return;
            _presenting = false;
            setState(() {});
            final latest = _state;
            if (latest != null) _armBot(latest);
            _checkTimeout();
          }),
    );
  }

  Set<String> _currentMutedIds([MatchState? state]) {
    final s = state ?? _state;
    return {
      if (s != null) ...[
        for (final seat in s.players)
          if (seat.micMuted) seat.id,
        for (final id in (s.board['mutedMics'] as List? ?? const [])) '$id',
      ],
      ..._voiceBanned,
    };
  }

  /// The voice participants row: sourced from the ACTUAL LiveKit room
  /// roster, so observers who never take a seat are visible too. When the
  /// roster cannot be read, a clearly labelled note is shown instead of a
  /// silently incomplete list.
  Widget _voiceParticipantsRow(MatchState? state) {
    final scope = _scope;
    if (!scope.voice.connected) return const SizedBox.shrink();
    if (_voiceRosterFailed) {
      return const Padding(
        padding: EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        child: Text(
          'تعذّر تحديث قائمة المشاركين في الصوت؛ المعروض قد لا يكون كاملاً',
          style: TextStyle(fontSize: 12),
          textAlign: TextAlign.center,
        ),
      );
    }
    final roster = _voiceRoster;
    if (roster == null || roster.isEmpty) return const SizedBox.shrink();
    final muted = _currentMutedIds(state);
    final me = scope.settings.playerId;
    return Semantics(
      label: 'المشاركون في المحادثة الصوتية',
      container: true,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Wrap(
          alignment: WrapAlignment.center,
          spacing: 6,
          runSpacing: 4,
          children: [
            for (final id in roster)
              if (id != me)
                _voiceParticipantChip(id, state, muted.contains(id)),
          ],
        ),
      ),
    );
  }

  Widget _voiceParticipantChip(String id, MatchState? state, bool muted) {
    final seat = state?.players.where((s) => s.id == id).firstOrNull;
    final label = seat?.name ??
        'مشارك صوتي ${id.length <= 4 ? id : id.substring(0, 4)}';
    return ActionChip(
      avatar: Icon(muted ? Icons.mic_off : Icons.mic, size: 16),
      label: Text(label),
      onPressed: () => _onVoiceParticipantTap(id, seat),
    );
  }

  /// Host moderation for a roster participant. Seated participants use the
  /// full seat sheet; a NON-SEATED participant (observer) gets voice-only
  /// controls (mute / voice ban) so the host can act on everyone in the
  /// room, per the owner's policy.
  Future<void> _onVoiceParticipantTap(String id, Seat? seat) async {
    final scope = _scope;
    final state = _state;
    if (state == null) return;
    if (seat != null) {
      await _onPlayerNameTap(seat, state);
      return;
    }
    final host = state.hostId == scope.settings.playerId;
    if (!host || id == state.hostId || widget.offline) return;
    final isMuted = _currentMutedIds(state).contains(id);
    await showModalBottomSheet<void>(
      context: context,
      builder: (sheet) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const ListTile(title: Text('مشارك صوتي')),
            ListTile(
              title: Text(isMuted ? 'إلغاء كتم الميكروفون' : 'كتم الميكروفون'),
              onTap: () async {
                Navigator.pop(sheet);
                final err = await scope.voiceAuthority
                    ?.setMuted(
                      tableId: widget.tableId,
                      targetId: id,
                      muted: !isMuted,
                    )
                    .then((_) => null, onError: (e) => e);
                if (err != null) {
                  await _message(
                    voiceActionFailureText(
                      err,
                      !isMuted ? 'الكتم' : 'إلغاء الكتم',
                    ),
                    actionLabel: 'إعادة المحاولة',
                    onAction: () async {
                      final retryErr = await scope.voiceAuthority
                          ?.setMuted(
                            tableId: widget.tableId,
                            targetId: id,
                            muted: !isMuted,
                          )
                          .then((_) => null, onError: (e) => e);
                      if (retryErr != null) {
                        await _message(
                          voiceActionFailureText(
                            retryErr,
                            !isMuted ? 'الكتم' : 'إلغاء الكتم',
                          ),
                        );
                      }
                    },
                  );
                }
              },
            ),
            ListTile(
              title: const Text('منع من المحادثة الصوتية'),
              onTap: () async {
                Navigator.pop(sheet);
                final banErr = await scope.voiceAuthority
                    ?.kick(tableId: widget.tableId, targetId: id)
                    .then((_) => null, onError: (e) => e);
                if (banErr != null) {
                  await _message(
                    voiceActionFailureText(banErr, 'المنع الصوتي'),
                    actionLabel: 'إعادة المحاولة',
                    onAction: () async {
                      final retryErr = await scope.voiceAuthority
                          ?.kick(tableId: widget.tableId, targetId: id)
                          .then((_) => null, onError: (e) => e);
                      if (retryErr != null) {
                        await _message(
                          voiceActionFailureText(retryErr, 'المنع الصوتي'),
                        );
                      }
                    },
                  );
                }
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _joinVoice(MatchState state) async {
    final scope = _scope;
    final muted = _currentMutedIds(state);
    // New-authority tables (a voiceRooms doc exists): only admitted members
    // may join. Before admission lands, wait quietly - the voiceRooms
    // listener retries the moment the host's client writes our entry.
    if (_voiceRoomExists == true && !_voiceMemberOk) {
      return;
    }
    await scope.voice.applyHostMutes(muted);
    final error = await scope.voice.joinAsListener(
      identity: scope.settings.playerId,
      displayName: scope.settings.displayName,
      tableId: widget.tableId,
      autoEnableMic: scope.settings.autoMicOnJoin,
    );
    if (!mounted) return;
    setState(() {});
    if (error != null) {
      await _message(error);
    } else if (scope.voice.connected) {
      unawaited(
        scope.voiceAuthority
            ?.setPresent(
              tableId: widget.tableId,
              uid: scope.settings.playerId,
              present: true,
            )
            .onError((_, _) {}),
      );
      unawaited(scope.sounds.play('voice_join'));
    }
  }

  Future<void> _returnToListener() async {
    final error = await _scope.voice.returnToListener();
    if (!mounted) return;
    setState(() {});
    if (error != null) await _message(error);
  }

  // ---------------------------------------------------------------------
  // Presence & 60 s reconnect grace.

  void _startPresence(MatchState state) {
    if (widget.offline || _presenceStarted) {
      return;
    }
    _presenceStarted = true;
    final scope = _scope;
    final me = scope.settings.playerId;
    final presence = scope.presence;
    final isHost = state.hostId == me;
    unawaited(presence.joinTable(tableId: widget.tableId, host: isHost));
    _connSub = presence.connection.listen((connected) {
      if (!mounted) {
        return;
      }
      setState(() => _selfReconnecting = !connected);
      if (connected) {
        final seat = _state?.players.where((s) => s.id == me).firstOrNull;
        if (seat != null && seat.reconnecting) {
          unawaited(
            scope.repo?.markReconnected(tableId: widget.tableId, playerId: me),
          );
        }
      }
    });
    if (isHost) {
      _seatSub = presence.watchSeats(widget.tableId).listen((ids) {
        final current = _state;
        if (current == null || !mounted) {
          return;
        }
        final humans = {
          for (final s in current.players)
            if (!s.isBot && s.id != me) s.id,
        };
        final diff = presenceDiff(
          seenBefore: _seenSeats,
          now: ids,
          humans: humans,
        );
        _seenSeats.addAll(ids);
        for (final id in diff.dropped) {
          final seat = current.players.where((s) => s.id == id).firstOrNull;
          if (seat != null && !seat.reconnecting) {
            unawaited(
              scope.repo?.markReconnecting(
                tableId: widget.tableId,
                playerId: id,
              ),
            );
          }
        }
        for (final id in diff.returned) {
          final seat = current.players.where((s) => s.id == id).firstOrNull;
          if (seat != null && seat.reconnecting) {
            unawaited(
              scope.repo?.markReconnected(
                tableId: widget.tableId,
                playerId: id,
              ),
            );
          }
        }
      }, onError: (_) {});
    } else {
      _hostSub = presence.watchHost(widget.tableId).listen((hostId) {
        if (!mounted) {
          return;
        }
        final current = _state;
        if (hostId != null) {
          _hostSeen = true;
          if (_hostLostAt != null) {
            setState(() => _hostLostAt = null);
          }
          return;
        }
        if (_hostSeen && _hostLostAt == null && current != null) {
          setState(() => _hostLostAt = DateTime.now().millisecondsSinceEpoch);
          scope.sounds.play('disconnect');
          _appendLocal(kind: 'system', text: 'المضيف: $reconnectingLabel');
          unawaited(
            scope.repo?.markReconnecting(
              tableId: widget.tableId,
              playerId: current.hostId,
            ),
          );
        }
      }, onError: (_) {});
    }
  }

  void _tick() {
    if (!mounted) {
      return;
    }
    _checkTimeout();
    final state = _state;
    if (state != null && state.game == gameThousandMiles) {
      _milesCoupTick(state);
    }
    if (state == null || widget.offline) {
      return;
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    final me = _scope.settings.playerId;
    if (state.hostId == me && now - _lastBeat > 60000) {
      // Liveness for the ghost-table sweep (no Cloud Functions on Spark).
      _lastBeat = now;
      unawaited(_scope.repo?.heartbeat(widget.tableId));
    }
    final anyReconnecting = state.players.any((s) => s.reconnecting);
    if (anyReconnecting || _hostLostAt != null) {
      setState(() {}); // refresh countdown labels
    }
    if (state.hostId == me && anyReconnecting) {
      final expired = state.players.any(
        (s) =>
            !s.isBot &&
            s.id != me &&
            graceStatus(
                  disconnectedAtMillis: s.reconnectingSince,
                  nowMillis: now,
                ) ==
                GraceStatus.expired,
      );
      if (expired && _graceSweepAt != state.nonce) {
        _graceSweepAt = state.nonce;
        unawaited(
          _scope.repo?.expireGrace(tableId: widget.tableId, hostId: me),
        );
      }
    }
    final lost = _hostLostAt;
    if (lost != null &&
        graceStatus(disconnectedAtMillis: lost, nowMillis: now) ==
            GraceStatus.expired) {
      // Host never came back: cascade-clean the Firestore table.
      _hostLostAt = null;
      unawaited(_cascadeDelete());
    }
  }

  Future<void> _cascadeDelete() async {
    try {
      await _scope.repo?.deleteTableCompletely(widget.tableId);
    } catch (_) {}
    unawaited(_scope.presence.removeTable(widget.tableId));
    if (mounted) {
      _kickToMenu('انقطع المضيف — أُغلقت الطاولة');
    }
  }

  // ---------------------------------------------------------------------
  // Reactions, sounds, announcements.

  /// Speaks once: the screen reader announcement, or the in-app TTS when
  /// the user chose it — never both (that caused double speech).
  void _say(String text) {
    final scope = _scope;
    if (scope.settings.useInternalTts) {
      unawaited(scope.speech.say(text, useInternalTts: true));
    } else {
      scope.speech.announce(text);
    }
  }

  Future<void> _react(MatchState? prev, MatchState next) async {
    final scope = _scope;
    final me = scope.settings.playerId;
    final mutedIds = _currentMutedIds(next);
    unawaited(scope.voice.applyHostMutes(mutedIds));
    if (mutedIds.contains(me) && scope.voice.micOn) {
      unawaited(_setMic(false));
    }
    if (prev != null && prev.status == 'waiting' && next.status == 'playing') {
      final line = settingsAnnouncement(next);
      _say(line);
      _appendLocal(kind: 'system', text: line);
    }
    String? resultText;
    if (next.game == gameEcho99) {
      final play = next.lastPlay;
      if (play != null && play.nonce != prev?.lastPlay?.nonce) {
        final card = PlayingCard.parse(next.lastCard);
        resultText = playSpeech(
          play.name,
          card == null ? play.value : card.englishName,
          play.score,
        );
      }
    } else if (next.cue != null && next.cue!.nonce != prev?.cue?.nonce) {
      final text = '${next.board['text'] ?? ''}';
      if (text.isNotEmpty) resultText = text;
    }
    final clips = presentationClips(prev, next, me);
    try {
      await scope.sounds.playNow(
        clips,
        speeds: [for (final clip in clips) clipPlaybackSpeed(clip)],
      );
    } catch (error) {
      if (error is PresentationCancelled) rethrow;
      // A failed movement sequence must not swallow the turn cue or freeze
      // the presentation queue; later steps still present their own audio.
      _say('تعذر إكمال صوت الحركة. راجع اختبار الصوت في الإعدادات.');
    }
    if (!mounted) return;
    if (resultText != null) {
      _appendPlay(resultText);
      if (scope.settings.speakPlays) {
        await scope.speech.ordered(
          resultText,
          useInternalTts: scope.settings.useInternalTts,
        );
      }
    }
    if (!mounted || _presentationPaused) return;
    if (next.game == gameThousandMiles) _announceCoup(next);
    if (prev != null) {
      if (scope.settings.speakPlays) {
        for (final line in seatChangeSpeechLines(prev, next, me)) {
          _say(line);
        }
      }
      for (final clip in tableSeatAudio(prev, next, me)) {
        unawaited(scope.sounds.play(clip));
      }
      for (final seat in next.players) {
        final before = prev.players.where((s) => s.id == seat.id).firstOrNull;
        if (before != null && !before.reconnecting && seat.reconnecting) {
          _appendLocal(
            kind: 'system',
            text: '${seat.name}: $reconnectingLabel',
          );
        }
      }
      if (next.status == 'playing' &&
          next.current?.id == me &&
          prev.current?.id != me) {
        await scope.sounds.playNow(['your_turn']);
      }
    }
  }

  void _appendPlay(String text) {
    _appendLocal(kind: 'play', text: text);
    if (_online) {
      _scope.repo?.appendLog(tableId: widget.tableId, kind: 'play', text: text);
    }
  }

  void _appendSystem(String text) {
    _appendLocal(kind: 'system', text: text);
    if (_online) {
      final scope = _scope;
      scope.repo?.appendLog(
        tableId: widget.tableId,
        kind: 'system',
        text: text,
        authorId: scope.settings.playerId,
        authorName: scope.settings.displayName,
      );
    }
  }

  void _appendLocal({required String kind, required String text}) {
    final entry = TableLogEntry(
      id: 'local${_localLog.length}',
      kind: kind,
      text: text,
      atMillis: DateTime.now().millisecondsSinceEpoch,
    );
    if (!mounted) {
      return;
    }
    setState(() => _localLog.add(entry));
    _publishLog();
  }

  void _publishLog() {
    // Online: the Firestore log is shared; local-only lines (e.g.
    // «Reconnecting...» seen by this device) are merged in by time.
    final merged = widget.offline
        ? [..._localLog]
        : [
            ..._log,
            for (final e in _localLog)
              if (!_log.any((l) => l.text == e.text && l.kind == e.kind)) e,
          ];
    merged.sort((a, b) => a.atMillis.compareTo(b.atMillis));
    _logEntries.value = merged;
  }

  void _publishPrivate() {
    final all = [..._receivedPrivate, ..._sentPrivate]
      ..sort((a, b) => a.atMillis.compareTo(b.atMillis));
    _privateMessages.value = all;
  }

  // ---------------------------------------------------------------------
  // Bots & timer.

  void _armBot(MatchState state) {
    final scope = _scope;
    if (_presentationPaused ||
        _presenting ||
        state.hostId != scope.settings.playerId) {
      return;
    }
    final seat = state.current;
    if (state.status != 'playing' || seat == null || !seat.isBot) {
      _bot?.cancel();
      return;
    }
    if (_botArmed == state.nonce) {
      return;
    }
    _botArmed = state.nonce;
    _bot?.cancel();
    final nonce = state.nonce;
    _bot = Timer(Duration(milliseconds: scope.settings.botMillis), () {
      if (!mounted || _state?.nonce != nonce) {
        return;
      }
      _autoPlay();
    });
  }

  void _checkTimeout() {
    final state = _state;
    if (!mounted || state == null || _presenting || _presentationPaused) {
      return;
    }
    if (state.hostId != _scope.settings.playerId || state.status != 'playing') {
      return;
    }
    if (state.timerSeconds < 10) {
      return;
    }
    if (remainingSeconds(state, DateTime.now().millisecondsSinceEpoch) > 0) {
      return;
    }
    if (_timeoutFired == state.nonce) {
      return;
    }
    _timeoutFired = state.nonce;
    _autoPlay();
  }

  Future<void> _autoPlay() async {
    final state = _state;
    final seat = state?.current;
    if (state == null || seat == null || _busy) {
      return;
    }
    switch (state.game) {
      case gameJackaroo:
        final move = chooseJackarooBot(state);
        if (move != null) {
          await _submitJackaroo(seat.id, move);
        }
      case gameSnakes:
        await _roll(seat.id);
      case gameLudo:
        final phase = '${state.board['phase'] ?? 'roll'}';
        if (phase == 'roll' || phase == 'colorRoll') {
          await _roll(seat.id);
        } else if (phase == 'colorPick') {
          if (state.board['colorPicker'] == seat.id) {
            final color = chooseLudoBotColor(state);
            if (color != null) await _pickLudoColor(seat.id, color);
          }
        } else {
          final piece = chooseLudoPiece(state);
          if (piece != null) await _moveLudo(seat.id, piece);
        }
      case gameThousandMiles:
        final phase = '${state.board['phase'] ?? 'draw'}';
        if (phase == 'draw') {
          await _drawMiles(seat.id);
        } else {
          final move = chooseMilesBotMove(state);
          if (move != null && milesCoupFor(state, seat.id) != null) {
            await _milesCoup(seat.id, move.card);
          } else if (move != null) {
            await _milesSubmit(
              seat.id,
              move.card,
              target: move.target,
              discardOnly: move.discard,
            );
          }
        }
      default:
        final pick = chooseBot(state);
        if (pick != null) {
          await _submit(seat.id, pick.card, pick.choice);
        }
    }
  }

  // ---------------------------------------------------------------------
  // Moves.

  Future<void> _runLocal(EngineResult Function(MatchState s) step) async {
    if (_presenting) return;
    final current = _state;
    if (current == null) {
      return;
    }
    final result = step(current);
    if (!mounted) {
      return;
    }
    if (result.error != null) {
      await _message(result.error);
      return;
    }
    _onState(result.state);
  }

  Future<void> _runRemote(Future<String?> Function() call) async {
    if (_busy || _presenting) {
      return;
    }
    _busy = true;
    final error = await call();
    _busy = false;
    if (mounted) {
      await _message(error);
    }
  }

  Future<void> _submit(String playerId, String card, int? choice) async {
    if (widget.offline) {
      await _runLocal(
        (s) => playCard(
          s,
          playerId: playerId,
          cardCode: card,
          choice: choice,
          random: _localRandom,
          nowMillis: DateTime.now().millisecondsSinceEpoch,
        ),
      );
      return;
    }
    final repo = _scope.repo;
    if (repo == null) {
      return;
    }
    await _runRemote(
      () => repo.play(
        tableId: widget.tableId,
        playerId: playerId,
        card: card,
        choice: choice,
      ),
    );
  }

  Future<void> _submitJackaroo(String playerId, JackarooMove move) async {
    if (widget.offline) {
      await _runLocal(
        (s) => playJackaroo(
          s,
          playerId: playerId,
          move: move,
          random: _localRandom,
          nowMillis: DateTime.now().millisecondsSinceEpoch,
        ),
      );
      return;
    }
    final repo = _scope.repo;
    if (repo == null) {
      return;
    }
    await _runRemote(
      () => repo.playJackarooMove(
        tableId: widget.tableId,
        playerId: playerId,
        move: move,
      ),
    );
  }

  Future<void> _roll(String playerId) async {
    if (widget.offline) {
      await _runLocal((s) {
        final roll = rollDie(_localRandom);
        final now = DateTime.now().millisecondsSinceEpoch;
        if (s.game == gameLudo) {
          return rollLudo(s, playerId: playerId, roll: roll, nowMillis: now);
        }
        return rollSnakes(s, playerId: playerId, roll: roll, nowMillis: now);
      });
      return;
    }
    final repo = _scope.repo;
    if (repo == null) {
      return;
    }
    await _runRemote(
      () => repo.rollDice(tableId: widget.tableId, playerId: playerId),
    );
  }

  Future<void> _pickLudoColor(String playerId, int colorIndex) async {
    if (widget.offline) {
      await _runLocal(
        (s) => pickLudoColor(
          s,
          playerId: playerId,
          colorIndex: colorIndex,
          nowMillis: DateTime.now().millisecondsSinceEpoch,
        ),
      );
      return;
    }
    final repo = _scope.repo;
    if (repo == null) return;
    await _runRemote(
      () => repo.chooseLudoColor(
        tableId: widget.tableId,
        playerId: playerId,
        colorIndex: colorIndex,
      ),
    );
  }

  Future<void> _moveLudo(String playerId, int piece) async {
    if (widget.offline) {
      await _runLocal(
        (s) => moveLudo(
          s,
          playerId: playerId,
          piece: piece,
          nowMillis: DateTime.now().millisecondsSinceEpoch,
        ),
      );
      return;
    }
    final repo = _scope.repo;
    if (repo == null) return;
    await _runRemote(
      () => repo.moveLudoPiece(
        tableId: widget.tableId,
        playerId: playerId,
        piece: piece,
      ),
    );
  }

  Future<void> _drawMiles(String playerId) async {
    if (widget.offline) {
      await _runLocal(
        (s) => drawMiles(
          s,
          playerId: playerId,
          random: _localRandom,
          nowMillis: DateTime.now().millisecondsSinceEpoch,
        ),
      );
      return;
    }
    final repo = _scope.repo;
    if (repo == null) return;
    await _runRemote(
      () => repo.drawMilesCard(tableId: widget.tableId, playerId: playerId),
    );
  }

  Future<void> _milesSubmit(
    String playerId,
    String code, {
    String? target,
    bool discardOnly = false,
  }) async {
    if (widget.offline) {
      await _runLocal(
        (s) => playMiles(
          s,
          playerId: playerId,
          card: code,
          targetId: target,
          discardOnly: discardOnly,
          random: _localRandom,
          nowMillis: DateTime.now().millisecondsSinceEpoch,
        ),
      );
      return;
    }
    final repo = _scope.repo;
    if (repo == null) return;
    await _runRemote(
      () => repo.playMilesCard(
        tableId: widget.tableId,
        playerId: playerId,
        card: code,
        targetId: target,
        discardOnly: discardOnly,
      ),
    );
  }

  Future<void> _milesCoup(String playerId, String code) async {
    if (widget.offline) {
      await _runLocal(
        (s) => coupFourreMiles(
          s,
          playerId: playerId,
          card: code,
          random: _localRandom,
          nowMillis: DateTime.now().millisecondsSinceEpoch,
        ),
      );
      return;
    }
    final repo = _scope.repo;
    if (repo == null) return;
    await _runRemote(
      () => repo.coupFourreMilesCard(
        tableId: widget.tableId,
        playerId: playerId,
        card: code,
      ),
    );
  }

  Future<void> _milesCloseCoup(String playerId) async {
    if (widget.offline) {
      await _runLocal(
        (s) => closeMilesCoup(
          s,
          playerId: playerId,
          random: _localRandom,
          nowMillis: DateTime.now().millisecondsSinceEpoch,
        ),
      );
      return;
    }
    final repo = _scope.repo;
    if (repo == null) return;
    await _runRemote(
      () => repo.closeMilesCoupWindow(
        tableId: widget.tableId,
        playerId: playerId,
      ),
    );
  }

  /// Announces an open coup-fourré chance to the holder (once per window).
  void _announceCoup(MatchState next) {
    final me = _scope.settings.playerId;
    final open = milesCoupFor(next, me);
    if (open == null) {
      _coupAnnounced = null;
      return;
    }
    final key = '${open.openedAt}';
    if (_coupAnnounced == key) return;
    _coupAnnounced = key;
    _scope.sounds.play('alert');
    _say(
      'خدعة متاحة: العب ${milesCardLabel(open.safety)} الآن لإلغاء '
      '${milesCardLabel(open.hazard)} والحصول على ٤٠٠ نقطة، أو اختر تجاهل',
    );
  }

  /// Host plays the coup for bots; in auto-draw mode the window closes
  /// after [milesCoupWindowMs] so the next player draws.
  void _milesCoupTick(MatchState state) {
    final coup = state.board['coup'];
    if (coup is! Map || _busy) return;
    final me = _scope.settings.playerId;
    final host = state.hostId == me;
    final openedAt = (coup['openedAt'] as num?)?.toInt() ?? 0;
    if (_coupHandled == state.nonce) return;
    final holders = milesCoupHolders(state);
    if (host) {
      for (final uid in holders) {
        final seat = state.players.where((p) => p.id == uid).firstOrNull;
        if (seat != null && seat.isBot) {
          _coupHandled = state.nonce;
          final open = milesCoupFor(state, uid);
          if (open != null) unawaited(_milesCoup(uid, open.safety));
          return;
        }
      }
    }
    final expired =
        DateTime.now().millisecondsSinceEpoch - openedAt >= milesCoupWindowMs;
    if (!expired || !MilesSettings.of(state).autoDraw) return;
    final current = state.current;
    if (current == null) return;
    final mine = current.id == me;
    final bot = host && current.isBot;
    if (mine || bot) {
      _coupHandled = state.nonce;
      unawaited(_milesCloseCoup(current.id));
    }
  }

  Future<void> _playMilesCard(String code, {required bool discardOnly}) async {
    final me = _scope.settings.playerId;
    final state = _state;
    if (state == null || _busy) return;
    final open = milesCoupFor(state, me);
    if (open != null && code == open.safety && !discardOnly) {
      await _milesCoup(me, code);
      return;
    }
    if (!_myTurn()) {
      _say('ليس دورك');
      return;
    }
    if ('${state.board['phase']}' == 'draw') {
      _say('اسحب ورقة أولاً: اسحب بثلاثة أصابع للأسفل أو اضغط زر سحب ورقة');
      return;
    }
    String? target;
    if (!discardOnly) {
      final why = milesPlayError(state, me, code);
      if (why != null) {
        _scope.sounds.play('jk_blocked');
        _say(
          '${milesCardLabel(code)} غير متاحة: $why. '
          'للتخلّص منها اضغط مطولاً',
        );
        return;
      }
      if (milesHazards.contains(code)) {
        final targets = milesLegalTargets(state, me, code);
        if (targets.isEmpty) {
          _say('لا توجد سيارة يمكن مهاجمتها بـ ${milesCardLabel(code)}');
          return;
        }
        target = targets.length == 1
            ? targets.single
            : await _pickMilesTarget(state, code, targets);
        if (target == null || !mounted) return;
      }
    }
    await _milesSubmit(me, code, target: target, discardOnly: discardOnly);
  }

  /// Accessible target picker: one button per legal car with its status.
  Future<String?> _pickMilesTarget(
    MatchState state,
    String code,
    List<String> targets,
  ) {
    return showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Semantics(
          header: true,
          child: Text('اختر السيارة التي تهاجمها بـ ${milesCardLabel(code)}'),
        ),
        children: [
          for (final carId in targets)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, carId),
              child: Text(milesCarLine(state, carId)),
            ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context),
            child: const Text('إلغاء'),
          ),
        ],
      ),
    );
  }

  bool _myTurn() {
    final state = _state;
    if (state == null || state.status != 'playing') {
      return false;
    }
    return state.current?.id == _scope.settings.playerId;
  }

  Future<void> _playMine(String code) async {
    if (_presenting) return;
    final state = _state;
    final scope = _scope;
    if (state == null) {
      return;
    }
    if (!_myTurn()) {
      if (state.game == gameJackaroo) {
        unawaited(scope.sounds.play('jk_invalid'));
      }
      await _message('ليس دورك');
      return;
    }
    if (state.game == gameJackaroo) {
      await _playJackarooCard(state, code);
      return;
    }
    final card = PlayingCard.parse(code);
    if (card == null) {
      return;
    }
    if (card.rank == 1 || card.rank == 10) {
      final choice = await showDialog<int>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(card.rank == 1 ? 'اختر قيمة الآس' : 'اختر قيمة العشرة'),
          actions: [
            for (final value
                in card.rank == 1 ? const [1, 11] : const [10, -10])
              TextButton(
                onPressed: () => Navigator.pop(context, value),
                child: Text('$value'),
              ),
          ],
        ),
      );
      if (choice == null || !mounted) {
        return;
      }
      await _submit(scope.settings.playerId, code, choice);
      return;
    }
    await _submit(scope.settings.playerId, code, null);
  }

  Future<void> _playJackarooCard(MatchState state, String code) async {
    if (_presenting) return;
    if (state.current?.id != _scope.settings.playerId) {
      await _scope.sounds.play('jk_invalid');
      return;
    }
    final me = _scope.settings.playerId;
    if (jackarooIsForcedToBurn(state, me)) {
      await _burnForcedCard(code);
      return;
    }
    var moves = jackarooMovesForCard(state, me, code);
    if (moves.isEmpty) {
      final all = jackarooLegalMoves(state, me);
      if (all.length == 1 && all.single.kind == 'burnAll') {
        moves = all;
      } else {
        _scope.sounds.play('jk_invalid');
        await _message('لا توجد حركة بهذه الورقة');
        return;
      }
    }
    JackarooMove? pick;
    final rank = PlayingCard.parse(code)?.rank;
    if (moves.length == 1) {
      pick = moves.single;
    } else {
      pick = await showDialog<JackarooMove>(
        context: context,
        builder: (context) => SimpleDialog(
          title: Semantics(
            header: true,
            child: Text(
              rank == 6
                  ? '${PlayingCard.parse(code)?.englishName ?? code}: اختر القطعة'
                  : PlayingCard.parse(code)?.englishName ?? code,
            ),
          ),
          children: [
            for (final move in moves)
              SimpleDialogOption(
                onPressed: () => Navigator.pop(context, move),
                child: Text(jackarooMoveLabel(state, move)),
              ),
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context),
              child: const Text('إلغاء'),
            ),
          ],
        ),
      );
    }
    if (pick == null || !mounted) {
      return;
    }
    await _submitJackaroo(me, pick);
  }

  // ---------------------------------------------------------------------
  // Announcements (Semantics custom actions).

  String _turnText(MatchState state) {
    final seat = state.current;
    if (state.status == 'finished') {
      final winner = state.players
          .where((s) => s.id == state.winnerId)
          .firstOrNull;
      return winner == null
          ? 'انتهت المباراة'
          : 'انتهت المباراة — فاز ${winner.name}';
    }
    if (state.status != 'playing' || seat == null) {
      return 'لا توجد جولة جارية';
    }
    final mine = seat.id == _scope.settings.playerId;
    return mine ? 'الدور الآن لك' : 'الدور الآن لـ ${seat.name}';
  }

  String _pileText(MatchState state) {
    final card = PlayingCard.parse(state.lastCard);
    if (card == null) {
      return 'مجموع الكومة هو ${state.pile}. لم تُلعب ورقة بعد.';
    }
    return 'مجموع الكومة هو ${state.pile}. آخر ورقة: ${card.englishName}.';
  }

  void _announce(String Function(MatchState s) build) {
    final state = _state;
    if (state == null) {
      return;
    }
    _say(build(state));
  }

  String _lastActionText(MatchState state) {
    switch (state.game) {
      case gameJackaroo:
      case gameLudo:
      case gameThousandMiles:
      case gameSnakes:
        final text = '${state.board['text'] ?? ''}';
        if (text.isNotEmpty) return text;
        if (state.game == gameEcho99) return _pileText(state);
        final roll = state.board['lastRoll'];
        return roll == null ? 'لا توجد حركة بعد' : 'آخر رمية: $roll';
      default:
        return _pileText(state);
    }
  }

  /// Same validated logic for every input path: VoiceOver three-finger
  /// swipe (accessibilityScroll), TalkBack two-finger swipe (raw touches),
  /// sighted two-finger swipe, and the custom actions below.
  void _onSwipe(GameSwipe swipe) {
    final state = _state;
    if (state == null) {
      _say('الطاولة لم تُحمّل بعد');
      return;
    }
    final miles = state.game == gameThousandMiles;
    switch (swipe) {
      case GameSwipe.up:
        _say(_turnText(state));
      case GameSwipe.down:
        if (miles) {
          _milesDrawGesture(state);
        } else {
          unawaited(_openBoardSheet());
        }
      case GameSwipe.left:
        _say(
          miles
              ? milesCarStateText(state, _scope.settings.playerId)
              : _lastActionText(state),
        );
      case GameSwipe.right:
        if (miles) {
          _say(milesBoardText(state));
        } else {
          unawaited(_openLog());
        }
    }
  }

  void _milesDrawGesture(MatchState state) {
    final me = _scope.settings.playerId;
    if (state.status != 'playing') {
      _say('المباراة ليست جارية');
    } else if (!_myTurn()) {
      _say('لا يمكنك السحب: ${_turnText(state)}');
    } else if ('${state.board['phase']}' != 'draw') {
      _say('سحبت بالفعل — العب ورقة أو تخلّص من ورقة');
    } else if (_busy) {
      _say('انتظر لحظة');
    } else {
      unawaited(_drawMiles(me));
    }
  }

  Map<CustomSemanticsAction, VoidCallback> _gameActions(MatchState? state) {
    final miles = state?.game == gameThousandMiles;
    return <CustomSemanticsAction, VoidCallback>{
      const CustomSemanticsAction(label: 'إعلان الدور'): () =>
          _onSwipe(GameSwipe.up),
      if (miles)
        const CustomSemanticsAction(label: 'سحب ورقة'): () =>
            _onSwipe(GameSwipe.down)
      else
        const CustomSemanticsAction(label: 'قائمة اللوحة والقطع'): () =>
            _onSwipe(GameSwipe.down),
      if (miles)
        const CustomSemanticsAction(label: 'حالة سيارتي'): () =>
            _onSwipe(GameSwipe.left)
      else
        const CustomSemanticsAction(label: 'آخر ورقة أو حركة'): () =>
            _onSwipe(GameSwipe.left),
      if (miles)
        const CustomSemanticsAction(label: 'حالة كل السيارات والكومة'): () =>
            _onSwipe(GameSwipe.right)
      else
        const CustomSemanticsAction(label: 'فتح السجل أو الدردشة'): () =>
            _onSwipe(GameSwipe.right),
      if (miles)
        const CustomSemanticsAction(label: 'النقاط'): () =>
            _announce(milesScoresText),
      if (miles)
        const CustomSemanticsAction(label: 'فتح السجل أو الدردشة'): _openLog,
    };
  }

  /// Lines for the Down gesture: one focusable row per piece / player.
  List<String> _boardLines(MatchState state) {
    switch (state.game) {
      case gameLudo:
        final pieces = ludoPieces(state);
        if (ludoColors(state).isEmpty) return [ludoPositionsText(state)];
        return [
          for (final seat in state.players)
            for (var i = 0; i < (pieces[seat.id]?.length ?? 0); i++)
              '${seat.name}: ${ludoPieceLabel(state, seat.id, i)}',
        ];
      case gameJackaroo:
        final board = JackarooBoard.of(state);
        return [
          for (final seat in state.players)
            for (var i = 0; i < (board.pieces[seat.id]?.length ?? 0); i++)
              '${seat.name}: ${jackarooPieceFullLabel(state, seat.id, i)}',
        ];
      case gameSnakes:
        final pos = snakesPositions(state);
        return [
          for (final seat in state.players)
            '${seat.name}: ${snakesSquareText(pos[seat.id] ?? 0)}',
        ];
      case gameThousandMiles:
        return [
          for (final id in milesCarIds(state)) milesCarLine(state, id),
          'الأوراق المتبقية في الكومة: ${state.deck.length}',
        ];
      default:
        return [
          _pileText(state),
          for (final seat in state.players) '${seat.name}: ${seat.points} نقاط',
        ];
    }
  }

  Future<void> _openBoardSheet() async {
    final state = _state;
    if (state == null || !mounted) return;
    final lines = _boardLines(state);
    if (lines.isEmpty) {
      _say('لا توجد قطع على اللوحة بعد');
      return;
    }
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheet) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(sheet).size.height * 0.8,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Semantics(
                header: true,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text('${gameLabel(state.game)} — اللوحة'),
                ),
              ),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final line in lines)
                      Semantics(
                        container: true,
                        child: ListTile(title: Text(line)),
                      ),
                  ],
                ),
              ),
              TextButton(
                onPressed: () => Navigator.pop(sheet),
                child: const Text('إغلاق'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _message(
    String? text, {
    String? actionLabel,
    VoidCallback? onAction,
  }) async {
    if (!mounted || text == null || text == 'watch') {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(text),
        action: actionLabel != null && onAction != null
            ? SnackBarAction(label: actionLabel, onPressed: onAction)
            : null,
      ),
    );
  }

  String _seatLabel(Seat seat, MatchState state) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final hostLost = seat.id == state.hostId && _hostLostAt != null;
    if (seat.reconnecting || hostLost) {
      final since = seat.reconnecting ? seat.reconnectingSince : _hostLostAt!;
      final left = graceSecondsLeft(
        disconnectedAtMillis: since,
        nowMillis: now,
      );
      return '${seat.name} · $reconnectingLabel ($left)';
    }
    return seat.name;
  }

  Future<void> _onPlayerNameTap(Seat seat, MatchState state) async {
    final scope = _scope;
    final host = state.hostId == scope.settings.playerId;
    if (!host || seat.id == state.hostId) {
      await showProfileDialog(
        context,
        uid: seat.id,
        name: seat.name,
        isBot: seat.isBot,
      );
      return;
    }
    final legacyMuted = [
      for (final id in (state.board['mutedMics'] as List? ?? const [])) '$id',
    ];
    final legacyBlocked = [
      for (final id in (state.board['blockedChat'] as List? ?? const [])) '$id',
    ];
    final isMuted = seat.micMuted || legacyMuted.contains(seat.id);
    final isBlocked = seat.chatBlocked || legacyBlocked.contains(seat.id);
    await showModalBottomSheet<void>(
      context: context,
      builder: (sheet) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(title: Text(seat.name)),
            ListTile(
              title: Text(isMuted ? 'إلغاء كتم الميكروفون' : 'كتم الميكروفون'),
              onTap: () async {
                Navigator.pop(sheet);
                if (widget.offline) return;
                await scope.repo?.hostSeatControl(
                  tableId: widget.tableId,
                  hostId: scope.settings.playerId,
                  targetId: seat.id,
                  action: isMuted ? 'unmute' : 'mute',
                );
                final voiceMuteErr = await scope.voiceAuthority
                    ?.setMuted(
                      tableId: widget.tableId,
                      targetId: seat.id,
                      muted: !isMuted,
                    )
                    .then((_) => null, onError: (e) => e);
                if (voiceMuteErr != null) {
                  await _message(
                    voiceActionFailureText(
                      voiceMuteErr,
                      !isMuted ? 'الكتم' : 'إلغاء الكتم',
                    ),
                    actionLabel: 'إعادة المحاولة',
                    onAction: () async {
                      final retryErr = await scope.voiceAuthority
                          ?.setMuted(
                            tableId: widget.tableId,
                            targetId: seat.id,
                            muted: !isMuted,
                          )
                          .then((_) => null, onError: (e) => e);
                      if (retryErr != null) {
                        await _message(
                          voiceActionFailureText(
                            retryErr,
                            !isMuted ? 'الكتم' : 'إلغاء الكتم',
                          ),
                        );
                      }
                    },
                  );
                }
                // Local LiveKit: mute own mic if we are the target (remote mute best-effort).
                if (seat.id == scope.settings.playerId) {
                  await _setMic(false);
                }
              },
            ),
            ListTile(
              title: const Text('منع من المحادثة الصوتية'),
              onTap: () async {
                Navigator.pop(sheet);
                if (widget.offline) return;
                // Voice ban only: the player stays seated at the table.
                final banErr = await scope.voiceAuthority
                    ?.kick(tableId: widget.tableId, targetId: seat.id)
                    .then((_) => null, onError: (e) => e);
                if (banErr != null) {
                  await _message(
                    voiceActionFailureText(banErr, 'المنع الصوتي'),
                    actionLabel: 'إعادة المحاولة',
                    onAction: () async {
                      final retryErr = await scope.voiceAuthority
                          ?.kick(tableId: widget.tableId, targetId: seat.id)
                          .then((_) => null, onError: (e) => e);
                      if (retryErr != null) {
                        await _message(
                          voiceActionFailureText(retryErr, 'المنع الصوتي'),
                        );
                      }
                    },
                  );
                }
              },
            ),
            ListTile(
              title: Text(isBlocked ? 'إلغاء حظر الدردشة' : 'حظر الدردشة'),
              onTap: () async {
                Navigator.pop(sheet);
                if (widget.offline) return;
                await scope.repo?.hostSeatControl(
                  tableId: widget.tableId,
                  hostId: scope.settings.playerId,
                  targetId: seat.id,
                  action: isBlocked ? 'unblockChat' : 'blockChat',
                );
              },
            ),
            ListTile(
              title: const Text('طرد'),
              onTap: () async {
                Navigator.pop(sheet);
                if (widget.offline) {
                  await _runLocal(
                    (s) => kickPlayer(
                      s,
                      seat.id,
                      DateTime.now().millisecondsSinceEpoch,
                    ),
                  );
                  return;
                }
                final kickError = await scope.repo?.kick(
                  tableId: widget.tableId,
                  hostId: scope.settings.playerId,
                  targetId: seat.id,
                );
                if (kickError == null) {
                  final voiceKickErr = await scope.voiceAuthority
                      ?.kick(tableId: widget.tableId, targetId: seat.id)
                      .then((_) => null, onError: (e) => e);
                  if (voiceKickErr != null) {
                    await _message(
                      voiceActionFailureText(voiceKickErr, 'الطرد'),
                      actionLabel: 'إعادة المحاولة',
                      onAction: () async {
                        final retryErr = await scope.voiceAuthority
                            ?.kick(tableId: widget.tableId, targetId: seat.id)
                            .then((_) => null, onError: (e) => e);
                        if (retryErr != null) {
                          await _message(
                            voiceActionFailureText(retryErr, 'الطرد'),
                          );
                        }
                      },
                    );
                  }
                }
                await _message(kickError);
              },
            ),
            if (!seat.isBot)
              ListTile(
                title: const Text('استبدال ببوت'),
                onTap: () async {
                  Navigator.pop(sheet);
                  if (widget.offline) {
                    await _runLocal(
                      (s) => replaceWithBot(
                        s,
                        seat.id,
                        botId: 'bot${DateTime.now().microsecondsSinceEpoch}',
                        botName: 'بوت (${seat.name})',
                        nowMillis: DateTime.now().millisecondsSinceEpoch,
                      ),
                    );
                    unawaited(scope.sounds.play('join'));
                    return;
                  }
                  await scope.repo?.hostSeatControl(
                    tableId: widget.tableId,
                    hostId: scope.settings.playerId,
                    targetId: seat.id,
                    action: 'replaceBot',
                  );
                  unawaited(scope.sounds.play('join'));
                },
              ),
            ListTile(
              title: const Text('الملف الشخصي'),
              onTap: () {
                Navigator.pop(sheet);
                showProfileDialog(
                  context,
                  uid: seat.id,
                  name: seat.name,
                  isBot: seat.isBot,
                );
              },
            ),
            ListTile(
              title: const Text('إغلاق'),
              onTap: () => Navigator.pop(sheet),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _players() async {
    final state = _state;
    final scope = _scope;
    if (state == null) {
      return;
    }
    await showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) {
        final host = state.hostId == scope.settings.playerId;
        return SafeArea(
          child: ListView(
            children: [
              for (final seat in state.players)
                ListTile(
                  title: Text(_seatLabel(seat, state)),
                  subtitle: Text(
                    [
                      if (state.game == gameEcho99) '${seat.points} نقاط',
                      if (seat.isBot) 'بوت',
                      if (seat.id == state.hostId) 'المضيف',
                    ].join(' · '),
                  ),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    showProfileDialog(
                      context,
                      uid: seat.id,
                      name: seat.name,
                      isBot: seat.isBot,
                    );
                  },
                  trailing: host && seat.id != state.hostId
                      ? IconButton(
                          tooltip: 'طرد',
                          onPressed: () async {
                            Navigator.pop(sheetContext);
                            if (widget.offline) {
                              await _runLocal(
                                (s) => kickPlayer(
                                  s,
                                  seat.id,
                                  DateTime.now().millisecondsSinceEpoch,
                                ),
                              );
                              return;
                            }
                            final kickError = await scope.repo?.kick(
                              tableId: widget.tableId,
                              hostId: scope.settings.playerId,
                              targetId: seat.id,
                            );
                            if (kickError == null) {
                              final voiceKickErr = await scope.voiceAuthority
                                  ?.kick(
                                    tableId: widget.tableId,
                                    targetId: seat.id,
                                  )
                                  .then((_) => null, onError: (e) => e);
                              if (voiceKickErr != null) {
                                await _message(
                                  voiceActionFailureText(voiceKickErr, 'الطرد'),
                                  actionLabel: 'إعادة المحاولة',
                                  onAction: () async {
                                    final retryErr = await scope.voiceAuthority
                                        ?.kick(
                                          tableId: widget.tableId,
                                          targetId: seat.id,
                                        )
                                        .then((_) => null, onError: (e) => e);
                                    if (retryErr != null) {
                                      await _message(
                                        voiceActionFailureText(
                                          retryErr,
                                          'الطرد',
                                        ),
                                      );
                                    }
                                  },
                                );
                              }
                            }
                            await _message(kickError);
                          },
                          icon: const Icon(Icons.close),
                        )
                      : null,
                ),
              ListTile(
                title: const Text('إغلاق'),
                onTap: () => Navigator.pop(sheetContext),
              ),
            ],
          ),
        );
      },
    );
  }

  // ---------------------------------------------------------------------
  // Host controls.

  /// Settings dialog only when the host taps بدء; everyone then hears the
  /// settings line when the table turns to «playing».
  Future<void> _start() async {
    final state = _state;
    final scope = _scope;
    if (state == null) {
      return;
    }
    if (state.hostId != scope.settings.playerId) {
      await _message('فقط المضيف يستطيع البدء');
      return;
    }
    if (state.status == 'finished') {
      await _replay();
      return;
    }
    if (state.status != 'waiting') {
      await _message('المباراة بدأت');
      return;
    }
    if (state.game == gameEcho99) {
      final settings = await showDialog<TableSettings>(
        context: context,
        barrierDismissible: false,
        builder: (context) => _StartSettingsDialog(
          initial: TableSettings(
            startPoints: state.maxPoints,
            timerSeconds: state.timerSeconds,
            teamsEnabled: state.teamsEnabled,
          ),
        ),
      );
      if (settings == null || !mounted) {
        return;
      }
      if (widget.offline) {
        await _runLocal((current) {
          final applied = applySettings(current, settings);
          if (applied.error != null) {
            return applied;
          }
          return startGame(
            applied.state,
            _localRandom,
            DateTime.now().millisecondsSinceEpoch,
          );
        });
        return;
      }
      final repo = scope.repo;
      if (repo == null) {
        return;
      }
      final saveErr = await repo.updateSettings(
        tableId: widget.tableId,
        hostId: scope.settings.playerId,
        settings: settings,
      );
      if (saveErr != null) {
        await _message(saveErr);
        return;
      }
      _appendSystem(
        settingsAnnouncement(
          state.copyWith(
            maxPoints: settings.startPoints,
            timerSeconds: settings.timerSeconds,
          ),
        ),
      );
      await _message(
        await repo.start(
          tableId: widget.tableId,
          hostId: scope.settings.playerId,
        ),
      );
      return;
    }
    if (state.game == gameLudo) {
      final ludo = await showDialog<LudoSettings>(
        context: context,
        barrierDismissible: false,
        builder: (context) =>
            _LudoSettingsDialog(initial: LudoSettings.of(state)),
      );
      if (ludo == null || !mounted) return;
      if (widget.offline) {
        await _runLocal((current) {
          final applied = applyLudoSettings(current, ludo);
          if (applied.error != null) return applied;
          return startGame(
            applied.state,
            _localRandom,
            DateTime.now().millisecondsSinceEpoch,
          );
        });
        return;
      }
      final repo = scope.repo;
      if (repo == null) return;
      final err = await repo.updateLudoSettings(
        tableId: widget.tableId,
        hostId: scope.settings.playerId,
        settings: ludo,
      );
      if (err != null) {
        await _message(err);
        return;
      }
      await _message(
        await repo.start(
          tableId: widget.tableId,
          hostId: scope.settings.playerId,
        ),
      );
      return;
    }
    if (state.game == gameThousandMiles) {
      final miles = await showDialog<MilesSettings>(
        context: context,
        barrierDismissible: false,
        builder: (context) =>
            _MilesSettingsDialog(initial: MilesSettings.of(state)),
      );
      if (miles == null || !mounted) return;
      if (widget.offline) {
        await _runLocal((current) {
          final applied = applyMilesSettings(current, miles);
          if (applied.error != null) return applied;
          return startGame(
            applied.state,
            _localRandom,
            DateTime.now().millisecondsSinceEpoch,
          );
        });
        return;
      }
      final repo = scope.repo;
      if (repo == null) return;
      final err = await repo.updateMilesSettings(
        tableId: widget.tableId,
        hostId: scope.settings.playerId,
        settings: miles,
      );
      if (err != null) {
        await _message(err);
        return;
      }
      await _message(
        await repo.start(
          tableId: widget.tableId,
          hostId: scope.settings.playerId,
        ),
      );
      return;
    }
    final picked = await showDialog<_GameSettings>(
      context: context,
      barrierDismissible: false,
      builder: (context) => _GameSettingsDialog(
        showMode: state.game == gameJackaroo,
        initialMode: '${state.board['mode'] ?? jackarooStandard}',
        initialTimer: state.timerSeconds,
        showTeams: state.game == gameJackaroo && state.players.length == 4,
        initialTeams: state.board['teams'] != false,
      ),
    );
    if (picked == null || !mounted) {
      return;
    }
    if (widget.offline) {
      await _runLocal((current) {
        final applied = applyJackarooMode(
          current,
          picked.mode,
          picked.timer,
          teams: picked.teams,
        );
        var ready = applied.state;
        if (current.game == gameSnakes) {
          ready = ready.copyWith(board: const {});
        }
        return startGame(
          ready,
          _localRandom,
          DateTime.now().millisecondsSinceEpoch,
        );
      });
      return;
    }
    final repo = scope.repo;
    if (repo == null) {
      return;
    }
    final saveErr = state.game == gameJackaroo
        ? await repo.updateJackarooSettings(
            tableId: widget.tableId,
            hostId: scope.settings.playerId,
            mode: picked.mode,
            timerSeconds: picked.timer,
            teams: picked.teams,
          )
        : await repo.updateTimer(
            tableId: widget.tableId,
            hostId: scope.settings.playerId,
            timerSeconds: picked.timer,
          );
    if (saveErr != null) {
      await _message(saveErr);
      return;
    }
    await _message(
      await repo.start(
        tableId: widget.tableId,
        hostId: scope.settings.playerId,
      ),
    );
  }

  /// «إعادة اللعب»: same players & settings, fresh deal / board.
  Future<void> _replay() async {
    final state = _state;
    final scope = _scope;
    if (state == null || state.hostId != scope.settings.playerId) {
      await _message('فقط المضيف يستطيع إعادة اللعب');
      return;
    }
    if (widget.offline) {
      await _runLocal((current) {
        final reset = resetForReplay(current);
        if (reset.error != null) {
          return reset;
        }
        return startGame(
          reset.state,
          _localRandom,
          DateTime.now().millisecondsSinceEpoch,
        );
      });
      return;
    }
    await _message(
      await scope.repo?.replay(
        tableId: widget.tableId,
        hostId: scope.settings.playerId,
      ),
    );
  }

  Future<void> _addBot() async {
    final scope = _scope;
    final state = _state;
    if (widget.offline) {
      if (state != null && state.players.length >= maxSeatsFor(state.game)) {
        await _message('الحد ${maxSeatsFor(state.game)} لاعبين.');
        return;
      }
      await _runLocal((s) => addBot(s, nextLocalBotId(s), nextBotName(s)));
      return;
    }
    final err = await scope.repo?.addBot(
      tableId: widget.tableId,
      hostId: scope.settings.playerId,
    );
    await _message(err);
  }

  Future<void> _share() async {
    final scope = _scope;
    final next = !scope.voice.sharingAudio;
    final error = await scope.voice.setShareDeviceAudio(
      enabled: next,
      identity: scope.settings.playerId,
      displayName: scope.settings.displayName,
      tableId: widget.tableId,
    );
    if (mounted) {
      setState(() {});
      await _message(error);
    }
  }

  Future<void> _setMic(bool enabled) async {
    final scope = _scope;
    if (scope.voice.micOn == enabled) {
      return;
    }
    if (enabled) {
      final seat = _state?.players
          .where((s) => s.id == scope.settings.playerId)
          .firstOrNull;
      final legacy = [
        for (final id in (_state?.board['mutedMics'] as List? ?? const []))
          '$id',
      ];
      if (seat?.micMuted == true ||
          legacy.contains(scope.settings.playerId) ||
          scope.voice.hostMutedLocal) {
        await _message(VoiceRoom.hostMutedError);
        return;
      }
    }
    final error = await scope.voice.setMicrophone(
      enabled: enabled,
      identity: scope.settings.playerId,
      displayName: scope.settings.displayName,
      tableId: widget.tableId,
    );
    if (error == null) {
      await scope.sounds.play(enabled ? 'voice_join' : 'mic_off');
      _appendSystem(
        enabled
            ? '${scope.settings.displayName} فعّل الميكروفون'
            : '${scope.settings.displayName} أغلق الميكروفون',
      );
      if (enabled && _online) {
        // Re-start so Android upgrades the service to the microphone type.
        unawaited(TableForegroundService.start('Echo99 — الميكروفون مفتوح'));
      }
    }
    if (mounted) {
      setState(() {});
      await _message(error);
    }
  }

  Future<void> _toggleMic() async {
    await _setMic(!_scope.voice.micOn);
  }

  Future<void> _openLog() async {
    _publishLog();
    final scope = _scope;
    final me = scope.settings.playerId;
    final state = _state;
    final recipients = [
      for (final seat in state?.players ?? const <Seat>[])
        if (!seat.isBot && seat.id != me) seat,
    ];
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) {
        return _LogSheet(
          entries: _logEntries,
          privateMessages: _privateMessages,
          recipients: recipients,
          me: me,
          privateEnabled:
              _online && scope.social != null && !scope.account.guest,
          controller: _chatController,
          privateController: _privateController,
          onSend: (text) async {
            final seat = _state?.players.where((s) => s.id == me).firstOrNull;
            final legacy = [
              for (final id
                  in (_state?.board['blockedChat'] as List? ?? const []))
                '$id',
            ];
            if (seat?.chatBlocked == true || legacy.contains(me)) {
              await _message('الدردشة محظورة من المضيف');
              return;
            }
            final line = '${scope.settings.displayName}: $text';
            if (_online) {
              final err = await scope.repo?.appendLog(
                tableId: widget.tableId,
                kind: 'chat',
                text: line,
                authorId: me,
                authorName: scope.settings.displayName,
              );
              if (err != null) {
                await _message(err);
                return;
              }
            } else {
              _appendLocal(kind: 'chat', text: line);
            }
            scope.sounds.play('alert');
          },
          onSendPrivate: (to, text) async {
            final social = scope.social;
            if (social == null) {
              return 'تعذر الاتصال';
            }
            try {
              await social.sendPrivateMessage(
                fromUid: me,
                toUid: to.id,
                fromName: scope.settings.displayName,
                text: text,
              );
              _sentPrivate.add(
                PrivateMessage(
                  id: 'sent${_sentPrivate.length}',
                  fromUid: me,
                  fromName: scope.settings.displayName,
                  toUid: to.id,
                  text: 'إلى ${to.name}: $text',
                  atMillis: DateTime.now().millisecondsSinceEpoch,
                ),
              );
              _publishPrivate();
              scope.sounds.play('dm');
              return null;
            } catch (_) {
              return 'تعذر إرسال الرسالة';
            }
          },
        );
      },
    );
  }

  void _onLeave({bool fromDispose = false}) {
    if (_left) {
      return;
    }
    _left = true;
    final scope = _scope;
    if (!fromDispose && mounted) {
      scope.sounds.play('leave_table');
      if (scope.voice.connected) {
        scope.sounds.play('voice_leave');
      }
    }
    scope.voice.onPeerLost = null;
    unawaited(scope.voice.close());
    unawaited(TableForegroundService.stop());
    if (_online) {
      unawaited(scope.presence.leaveTable());
      final match = _state;
      final isHost = match != null && match.hostId == scope.settings.playerId;
      if (isHost) {
        unawaited(scope.repo?.deleteTableCompletely(widget.tableId));
      } else {
        unawaited(
          scope.repo?.leave(
            tableId: widget.tableId,
            playerId: scope.settings.playerId,
          ),
        );
      }
    }
  }

  // ---------------------------------------------------------------------
  // UI.

  Widget _optionsBar(MatchState? state) {
    final scope = _scope;
    final host = state != null && state.hostId == scope.settings.playerId;
    final finished = state?.status == 'finished';
    final items = <(String, VoidCallback)>[
      ('اللاعبون', _players),
      if (finished && host) ('إعادة اللعب', _replay) else ('بدء', _start),
      ('إضافة بوت', _addBot),
      ('مشاركة صوت الجهاز', _share),
      ('السجل', _openLog),
    ];
    Future<void> openSheet() async {
      await showModalBottomSheet<void>(
        context: context,
        builder: (sheet) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final item in items)
                ListTile(
                  title: Text(item.$1),
                  onTap: () {
                    Navigator.pop(sheet);
                    item.$2();
                  },
                ),
              ListTile(
                title: const Text('رجوع'),
                onTap: () {
                  Navigator.pop(sheet);
                  Navigator.of(context).maybePop();
                },
              ),
            ],
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: Row(
        children: [
          Expanded(
            child: GameNode(
              label: 'خيارات الطاولة',
              hint: 'اللاعبون، بدء، إضافة بوت، مشاركة الصوت، السجل',
              onTap: openSheet,
              extraActions: {
                for (final item in items)
                  CustomSemanticsAction(label: item.$1): item.$2,
              },
              child: OutlinedButton(
                onPressed: openSheet,
                child: const Text('خيارات الطاولة'),
              ),
            ),
          ),
          const SizedBox(width: 8),
          GameNode(
            label: 'السجل والدردشة',
            onTap: _openLog,
            child: OutlinedButton(
              onPressed: _openLog,
              child: const Text('السجل'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _statusLine(MatchState state) {
    final tail = state.game == gameEcho99 ? ' · الحد ${state.maxPoints}' : '';
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Wrap(
        spacing: 6,
        children: [
          Text('${gameLabel(state.game)} · ${state.name}'),
          for (final seat in state.players)
            GameNode(
              label: state.game == gameEcho99
                  ? '${_seatLabel(seat, state)}، ${seat.points} نقاط'
                  : _seatLabel(seat, state),
              hint: 'خيارات اللاعب',
              onTap: () => _onPlayerNameTap(seat, state),
              child: InkWell(
                onTap: () => _onPlayerNameTap(seat, state),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 4,
                    vertical: 2,
                  ),
                  child: Text(
                    state.game == gameEcho99
                        ? '${_seatLabel(seat, state)} (${seat.points})'
                        : _seatLabel(seat, state),
                    style: TextStyle(
                      decoration: TextDecoration.underline,
                      color:
                          state.current?.id == seat.id &&
                              state.status == 'playing'
                          ? const Color(0xFFE8C872)
                          : null,
                    ),
                  ),
                ),
              ),
            ),
          if (tail.isNotEmpty) Text(tail),
        ],
      ),
    );
  }

  Widget _finishedBanner(MatchState state) {
    final host = state.hostId == _scope.settings.playerId;
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Semantics(
            liveRegion: true,
            container: true,
            button: false,
            label: _turnText(state),
            child: ExcludeSemantics(
              child: Text(
                _turnText(state),
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),
          if (host)
            FilledButton(
              key: const Key('replay_button'),
              onPressed: _replay,
              child: const Text('إعادة اللعب'),
            )
          else
            const Text('بانتظار المضيف لإعادة اللعب'),
        ],
      ),
    );
  }

  Widget _hand(List<String> codes, {bool forceBurn = false}) {
    final cards = [
      for (final code in codes)
        if (PlayingCard.parse(code) != null) PlayingCard.parse(code)!,
    ];
    return Wrap(
      alignment: WrapAlignment.center,
      children: [
        for (final card in cards)
          PlayingCardFace(
            key: ValueKey('hand-${card.code}'),
            card: card,
            nameCards: _scope.settings.nameCards,
            labelOverride: forceBurn
                ? 'حرق ${_scope.settings.nameCards ? card.englishName : card.arabicName}'
                : null,
            onPlay: () =>
                forceBurn ? _burnForcedCard(card.code) : _playMine(card.code),
          ),
      ],
    );
  }

  Future<void> _burnForcedCard(String code) async {
    final me = _scope.settings.playerId;
    await _submitJackaroo(
      me,
      JackarooMove(card: code, kind: 'burnForced', owner: me),
    );
  }

  Widget _body(MatchState state) {
    final me = _scope.settings.playerId;
    if (state.status == 'finished') {
      return Center(child: _finishedBanner(state));
    }
    final hand = state.hands[me] ?? const <String>[];
    switch (state.game) {
      case gameJackaroo:
        final burn = jackarooIsForcedToBurn(state, me);
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (state.status != 'playing')
              const Padding(
                padding: EdgeInsets.all(12),
                child: Text('جاكارو — 2 إلى 4 لاعبين. اضغط بدء.'),
              )
            else ...[
              if (burn)
                const Padding(
                  padding: EdgeInsets.all(8),
                  child: Text('يجب حرق ورقة — اضغط أي ورقة لحرقها'),
                ),
            ],
            _hand(hand, forceBurn: burn),
          ],
        );
      case gameLudo:
        return _ludoBody(state, me);
      case gameThousandMiles:
        return _milesBody(state, me);
      case gameSnakes:
        final last = state.board['lastRoll'];
        final pos = snakesPositions(state);
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (state.status != 'playing')
              const Padding(
                padding: EdgeInsets.all(12),
                child: Text('السلم والثعبان — 2 إلى 6 لاعبين. اضغط بدء.'),
              )
            else
              Wrap(
                alignment: WrapAlignment.center,
                spacing: 4,
                runSpacing: 4,
                children: [
                  for (final seat in state.players)
                    GameNode(
                      button: false,
                      label:
                          '${seat.name}: ${snakesSquareText(pos[seat.id] ?? 0)}',
                      child: _pieceChip(
                        '${seat.name}: ${snakesSquareText(pos[seat.id] ?? 0)}',
                      ),
                    ),
                ],
              ),
            if (last != null)
              GameNode(
                button: false,
                label: 'آخر رمية: $last',
                child: Text('آخر رمية: $last'),
              ),
            const SizedBox(height: 12),
            if (state.status == 'playing')
              _bigButton(
                key: const Key('roll_button'),
                label: _myTurn() ? 'رمي النرد' : _turnText(state),
                hint: _myTurn() ? null : 'ليس دورك',
                onTap: _myTurn() && !_busy ? () => _roll(me) : null,
              ),
          ],
        );
      default:
        return _hand(hand);
    }
  }

  Widget _pieceChip(String text, {bool selected = false}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: selected ? const Color(0xFFE8C872) : const Color(0xFF57534E),
          width: selected ? 3 : 1,
        ),
      ),
      child: Text(text, textAlign: TextAlign.center),
    );
  }

  Widget _bigButton({
    Key? key,
    required String label,
    String? hint,
    VoidCallback? onTap,
    Map<CustomSemanticsAction, VoidCallback> extraActions = const {},
  }) {
    return GameNode(
      key: key,
      label: label,
      hint: hint,
      onTap: onTap,
      extraActions: extraActions,
      child: FilledButton(
        onPressed: onTap,
        style: FilledButton.styleFrom(minimumSize: const Size(200, 64)),
        child: Text(label),
      ),
    );
  }

  Widget _ludoBody(MatchState state, String me) {
    final phase = '${state.board['phase'] ?? 'roll'}';
    final last = state.board['lastRoll'];
    if (state.status != 'playing') {
      return const Padding(
        padding: EdgeInsets.all(12),
        child: Text('اللودو — 2 إلى 4 لاعبين. اضغط بدء.'),
      );
    }
    final pieces = ludoPieces(state);
    final colored = ludoColors(state).isNotEmpty;
    final roll = (state.board['pendingRoll'] as num?)?.toInt() ?? 0;
    final legal = phase == 'move' && _myTurn()
        ? ludoLegalMoves(state, me, roll)
        : const <LudoMoveOption>[];
    final selected = _ludoSelected;
    final selectedLegal =
        selected != null && legal.any((m) => m.piece == selected);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (!colored)
          Padding(
            padding: const EdgeInsets.all(12),
            child: Text(ludoPositionsText(state)),
          )
        else if (phase == 'move' && _myTurn())
          Wrap(
            alignment: WrapAlignment.center,
            spacing: 4,
            runSpacing: 4,
            children: [
              for (var i = 0; i < (pieces[me]?.length ?? 0); i++)
                if (legal.any((m) => m.piece == i))
                  GameNode(
                    key: ValueKey('ludo-piece-$i'),
                    label: ludoPieceLabel(state, me, i),
                    hint: 'اضغط للاختيار ثم اضغط تحريك',
                    selected: selected == i,
                    onTap: () => _selectLudoPiece(state, me, i, legal),
                    child: _pieceChip(
                      ludoPieceLabel(state, me, i),
                      selected: selected == i,
                    ),
                  ),
            ],
          ),
        if (last != null)
          GameNode(
            button: false,
            label: 'آخر رمية: $last',
            child: Text('آخر رمية: $last'),
          ),
        const SizedBox(height: 8),
        if (phase == 'roll' || phase == 'colorRoll')
          _bigButton(
            key: const Key('roll_button'),
            label: _myTurn()
                ? (phase == 'colorRoll' ? 'رمي لاختيار اللون' : 'رمي النرد')
                : _turnText(state),
            hint: _myTurn() ? null : 'ليس دورك',
            onTap: _myTurn() && !_busy ? () => _roll(me) : null,
          ),
        if (phase == 'colorPick') ...[
          Text(
            state.board['colorPicker'] == me
                ? 'اختر لونك'
                : 'بانتظار اختيار اللون',
          ),
          if (state.board['colorPicker'] == me)
            Wrap(
              alignment: WrapAlignment.center,
              spacing: 8,
              children: [
                for (var i = 0; i < 4; i++)
                  GameNode(
                    label: 'اللون ${ludoColorsAr[i]}',
                    onTap: !_busy ? () => _pickLudoColor(me, i) : null,
                    child: FilledButton(
                      onPressed: !_busy ? () => _pickLudoColor(me, i) : null,
                      child: Text(ludoColorsAr[i]),
                    ),
                  ),
              ],
            ),
        ],
        if (phase == 'move' && _myTurn()) ...[
          GameNode(
            button: false,
            label: ludoMovesText(state, me, legal),
            child: Text(ludoMovesText(state, me, legal)),
          ),
          const SizedBox(height: 8),
          _bigButton(
            key: const Key('ludo_move_button'),
            label: selectedLegal
                ? 'تحريك ${ludoPieceName(ludoColors(state)[me] ?? 0, selected)}'
                : 'تحريك — اختر قطعة أولاً',
            hint: selectedLegal ? null : 'اختر إحدى قطعك المتاحة',
            onTap: selectedLegal && !_busy
                ? () {
                    final piece = selected;
                    setState(() => _ludoSelected = null);
                    unawaited(_moveLudo(me, piece));
                  }
                : null,
          ),
        ],
      ],
    );
  }

  void _selectLudoPiece(
    MatchState state,
    String me,
    int piece,
    List<LudoMoveOption> legal,
  ) {
    final name = ludoPieceName(ludoColors(state)[me] ?? 0, piece);
    if (!_myTurn()) {
      _say('ليس دورك — $name');
      return;
    }
    if ('${state.board['phase']}' != 'move') {
      _say('ارمِ النرد أولاً');
      return;
    }
    if (!legal.any((m) => m.piece == piece)) {
      final roll = state.board['pendingRoll'];
      _say(
        '$name لا تستطيع التحرك بالرمية $roll'
        '${ludoPieceWhere(state, me, piece) == 'في القاعدة' ? ' — تحتاج ستة للخروج' : ''}',
      );
      return;
    }
    setState(() => _ludoSelected = piece);
    _say('اخترت $name. اضغط تحريك');
  }

  Widget _milesBody(MatchState state, String me) {
    final phase = '${state.board['phase'] ?? 'draw'}';
    if (state.status != 'playing') {
      return const Padding(
        padding: EdgeInsets.all(12),
        child: Text(
          'ألف ميل — من ٢ إلى ٦ لاعبين فرديًا، أو فرق ٤، ٦، ٨، ٩. اضغط بدء.',
        ),
      );
    }
    final hand = state.hands[me] ?? const <String>[];
    final labels = milesHandLabels(state, me);
    final open = milesCoupFor(state, me);
    final canAct = _myTurn() && !_busy;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        GameNode(
          label: 'النقاط وحالة السيارات',
          hint: 'اضغط لسماع النقاط وكل السيارات وعدد أوراق الكومة',
          onTap: () =>
              _say('${milesScoresText(state)}. ${milesBoardText(state)}'),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Text(milesBoardText(state), textAlign: TextAlign.center),
          ),
        ),
        if (open != null) ...[
          _bigButton(
            key: const Key('miles_coup_button'),
            label:
                'خدعة! العب ${milesCardLabel(open.safety)} لإلغاء ${milesCardLabel(open.hazard)}',
            onTap: !_busy ? () => _milesCoup(me, open.safety) : null,
          ),
          const SizedBox(height: 6),
          GameNode(
            label: 'تجاهل الخدعة',
            onTap: !_busy ? () => _milesCloseCoup(me) : null,
            child: OutlinedButton(
              onPressed: !_busy ? () => _milesCloseCoup(me) : null,
              child: const Text('تجاهل'),
            ),
          ),
        ],
        if (phase == 'draw')
          _bigButton(
            key: const Key('miles_draw_button'),
            label: _myTurn() ? 'سحب ورقة' : _turnText(state),
            hint: _myTurn() ? 'أو اسحب بثلاثة أصابع للأسفل' : 'ليس دورك',
            onTap: canAct ? () => _drawMiles(me) : null,
          ),
        if (hand.isNotEmpty) ...[
          const SizedBox(height: 6),
          Text(
            phase == 'play' && _myTurn()
                ? 'اضغط للعب · اضغط مطولاً للتخلّص'
                : 'أوراقك',
          ),
          Wrap(
            alignment: WrapAlignment.center,
            children: [
              for (var i = 0; i < hand.length; i++)
                Padding(
                  padding: const EdgeInsets.all(4),
                  child: _milesCardNode(state, me, hand[i], labels[i], phase),
                ),
            ],
          ),
        ],
      ],
    );
  }

  Widget _milesCardNode(
    MatchState state,
    String me,
    String code,
    String label,
    String phase,
  ) {
    final ready = _myTurn() && phase == 'play' && !_busy;
    final why = ready ? milesPlayError(state, me, code) : null;
    final coup = milesCoupFor(state, me)?.safety == code;
    final hint = coup
        ? 'اضغط للعب الخدعة'
        : !_myTurn()
        ? 'ليس دورك'
        : phase != 'play'
        ? 'اسحب ورقة أولاً'
        : why == null
        ? 'اضغط للعب، اضغط مطولاً للتخلّص'
        : 'غير متاحة: $why. اضغط مطولاً للتخلّص';
    void play() => _playMilesCard(code, discardOnly: false);
    void discard() => _playMilesCard(code, discardOnly: true);
    return GameNode(
      label: label,
      hint: hint,
      onTap: play,
      onLongPress: ready ? discard : null,
      extraActions: {
        if (ready)
          const CustomSemanticsAction(label: 'تخلّص من الورقة'): discard,
      },
      child: OutlinedButton(
        onPressed: play,
        onLongPress: ready ? discard : null,
        child: Text(label),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = _state;
    final scope = EchoScope.of(context);
    return PopScope(
      canPop: true,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) {
          _onLeave();
        }
      },
      child: Scaffold(
        body: SafeArea(
          child: GameGestureSurface(
            onSwipe: _onSwipe,
            actions: _gameActions(state),

            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _optionsBar(state),
                Visibility(
                  key: const ValueKey('reconnecting-banner'),
                  visible: _selfReconnecting,
                  maintainState: true,
                  child: Semantics(
                    liveRegion: true,
                    child: Container(
                      color: const Color(0xFF7A4B00),
                      padding: const EdgeInsets.all(8),
                      child: const Text(
                        reconnectingLabel,
                        textAlign: TextAlign.center,
                      ),
                    ),
                  ),
                ),
                if (state != null) _statusLine(state),
                if (state != null && state.status == 'playing')
                  GameNode(
                    button: false,
                    label: _turnText(state),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: Text(_turnText(state)),
                    ),
                  ),
                Expanded(
                  child: GameScrollBody(
                    padding: const EdgeInsets.fromLTRB(8, 8, 8, 16),
                    child: Column(
                      key: const ValueKey('table-play-area'),
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (state == null)
                          const Center(child: CircularProgressIndicator())
                        else
                          Semantics(
                            sortKey: const OrdinalSortKey(1),
                            container: true,
                            explicitChildNodes: true,
                            child: _body(state),
                          ),
                        if (_online) _voiceParticipantsRow(state),
                        if (_online)
                          Semantics(
                            sortKey: const OrdinalSortKey(2),
                            container: true,
                            child: MicPad(
                              micOn: scope.voice.micOn,
                              onMicOn: () => _setMic(true),
                              onMicOff: () => _setMic(false),
                              onToggle: _toggleMic,
                            ),
                          ),
                        if (_online &&
                            scope.voice.linkState != VoiceLinkState.listener &&
                            scope.voice.linkState !=
                                VoiceLinkState.disconnected)
                          TextButton(
                            onPressed: _returnToListener,
                            child: const Text(
                              'الرجوع إلى الاستماع دون مغادرة الطاولة',
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _StartSettingsDialog extends StatelessWidget {
  const _StartSettingsDialog({required this.initial});

  final TableSettings initial;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('إعدادات الطاولة'),
      content: SizedBox(
        width: 360,
        height: 360,
        child: TableSettingsForm(
          initial: initial,
          submitLabel: 'تأكيد وبدء',
          onSubmit: (settings) async {
            Navigator.of(context).pop(settings);
            return null;
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('إلغاء'),
        ),
      ],
    );
  }
}

class _GameSettings {
  const _GameSettings(this.mode, this.timer, this.teams);
  final String mode;
  final int timer;

  /// 4-player Jackaroo only: teams (شركاء) vs individual. Null otherwise.
  final bool? teams;
}

/// Test hook: builds the start-settings dialog directly (private widget).
@visibleForTesting
Widget buildGameSettingsDialogForTest({
  required bool showMode,
  required String initialMode,
  required int initialTimer,
  bool showTeams = false,
  bool initialTeams = true,
}) {
  return _GameSettingsDialog(
    showMode: showMode,
    initialMode: initialMode,
    initialTimer: initialTimer,
    showTeams: showTeams,
    initialTeams: initialTeams,
  );
}

class _GameSettingsDialog extends StatefulWidget {
  const _GameSettingsDialog({
    required this.showMode,
    required this.initialMode,
    required this.initialTimer,
    this.showTeams = false,
    this.initialTeams = true,
  });

  final bool showMode;
  final String initialMode;
  final int initialTimer;

  /// 4-player Jackaroo: host picks teams vs individual (rules PDF).
  final bool showTeams;
  final bool initialTeams;

  @override
  State<_GameSettingsDialog> createState() => _GameSettingsDialogState();
}

class _GameSettingsDialogState extends State<_GameSettingsDialog> {
  late String _mode = widget.initialMode;
  late bool _teams = widget.initialTeams;
  late bool _timerOn = widget.initialTimer >= minTimerSeconds;
  late final _timer = TextEditingController(
    text: widget.initialTimer >= minTimerSeconds
        ? '${widget.initialTimer}'
        : '30',
  );
  String? _error;

  @override
  void dispose() {
    _timer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('إعدادات الطاولة'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (widget.showMode) ...[
              RadioGroup<String>(
                groupValue: _mode,
                onChanged: (v) => setState(() => _mode = v ?? _mode),
                child: const Column(
                  children: [
                    RadioListTile<String>(
                      value: jackarooStandard,
                      title: Text('الوضع العادي'),
                    ),
                    RadioListTile<String>(
                      value: jackarooComplex,
                      title: Text('الكومبلكس'),
                    ),
                  ],
                ),
              ),
            ],
            if (widget.showTeams) ...[
              RadioGroup<bool>(
                groupValue: _teams,
                onChanged: (v) => setState(() => _teams = v ?? _teams),
                child: const Column(
                  children: [
                    RadioListTile<bool>(
                      value: true,
                      title: Text('لعب الفرق'),
                      subtitle: Text('اثنان مقابل اثنين، الشريكان متقابلان'),
                    ),
                    RadioListTile<bool>(
                      value: false,
                      title: Text('اللعب الفردي'),
                      subtitle: Text('كل لاعب لنفسه، ولا شريك لأحد'),
                    ),
                  ],
                ),
              ),
            ],
            SwitchListTile(
              value: _timerOn,
              onChanged: (v) => setState(() => _timerOn = v),
              title: const Text('تفعيل مؤقت الدور'),
            ),
            if (_timerOn)
              TextField(
                controller: _timer,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                  labelText: 'مدة مؤقت الدور بالثواني',
                  errorText: _error,
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('إلغاء'),
        ),
        TextButton(
          onPressed: () {
            var timer = 0;
            if (_timerOn) {
              final value = int.tryParse(_timer.text.trim());
              if (value == null || value < minTimerSeconds) {
                setState(() => _error = timerError);
                return;
              }
              timer = value;
            }
            Navigator.of(context).pop(
              _GameSettings(_mode, timer, widget.showTeams ? _teams : null),
            );
          },
          child: const Text('تأكيد وبدء'),
        ),
      ],
    );
  }
}

/// السجل: الأحداث، الدردشة العامة، الرسائل الخاصة — each with a TextField.
class _LudoSettingsDialog extends StatefulWidget {
  const _LudoSettingsDialog({required this.initial});
  final LudoSettings initial;
  @override
  State<_LudoSettingsDialog> createState() => _LudoSettingsDialogState();
}

class _LudoSettingsDialogState extends State<_LudoSettingsDialog> {
  late String _mode = widget.initial.mode;
  late bool _fast = widget.initial.fast;
  late bool _kill = widget.initial.mandatoryKill;
  late bool _teams = widget.initial.teams;
  late bool _safe = widget.initial.safeSquares;
  late bool _timerOn = widget.initial.timerSeconds >= minTimerSeconds;
  late final _timer = TextEditingController(
    text: widget.initial.timerSeconds >= minTimerSeconds
        ? '${widget.initial.timerSeconds}'
        : '30',
  );
  String? _error;

  @override
  void dispose() {
    _timer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('إعدادات اللودو'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            RadioGroup<String>(
              groupValue: _mode,
              onChanged: (v) => setState(() => _mode = v ?? _mode),
              child: const Column(
                children: [
                  RadioListTile<String>(
                    value: ludoModeNormal,
                    title: Text('لودو عادي'),
                    subtitle: Text('لاعبان أو ٤ — الألوان المتقابلة فريق'),
                  ),
                  RadioListTile<String>(
                    value: ludoModeFree,
                    title: Text('لودو حر'),
                    subtitle: Text('٣ أو ٤ لاعبين — الكل يهاجم الكل'),
                  ),
                ],
              ),
            ),
            SwitchListTile(
              value: _fast,
              onChanged: (v) => setState(() => _fast = v),
              title: const Text('لودو السريع (قطعتان لكل لاعب)'),
            ),
            SwitchListTile(
              value: _safe,
              onChanged: (v) => setState(() => _safe = v),
              title: const Text('الخانات الآمنة'),
              subtitle: const Text('1، 9، 14، 22، 27، 35، 40، 48'),
            ),
            SwitchListTile(
              value: _kill,
              onChanged: (v) => setState(() => _kill = v),
              title: const Text('القتل الإجباري'),
            ),
            if (_mode != ludoModeFree)
              SwitchListTile(
                value: _teams,
                onChanged: (v) => setState(() => _teams = v),
                title: const Text('فرق (٤ لاعبين)'),
              ),
            SwitchListTile(
              value: _timerOn,
              onChanged: (v) => setState(() => _timerOn = v),
              title: const Text('تفعيل مؤقت الدور'),
            ),
            if (_timerOn)
              TextField(
                controller: _timer,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                  labelText: 'مدة مؤقت الدور بالثواني',
                  errorText: _error,
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('إلغاء'),
        ),
        TextButton(
          onPressed: () {
            var timer = 0;
            if (_timerOn) {
              final value = int.tryParse(_timer.text.trim());
              if (value == null || value < minTimerSeconds) {
                setState(() => _error = timerError);
                return;
              }
              timer = value;
            }
            Navigator.of(context).pop(
              LudoSettings(
                mode: _mode,
                fast: _fast,
                mandatoryKill: _kill,
                teams: _mode == ludoModeFree ? false : _teams,
                safeSquares: _safe,
                timerSeconds: timer,
              ),
            );
          },
          child: const Text('تأكيد وبدء'),
        ),
      ],
    );
  }
}

class _MilesSettingsDialog extends StatefulWidget {
  const _MilesSettingsDialog({required this.initial});
  final MilesSettings initial;
  @override
  State<_MilesSettingsDialog> createState() => _MilesSettingsDialogState();
}

class _MilesSettingsDialogState extends State<_MilesSettingsDialog> {
  late final _score = TextEditingController(
    text: '${widget.initial.scoreLimit}',
  );
  late bool _stack = widget.initial.stackHazards;
  late bool _reshuffle = widget.initial.reshuffleDiscard;
  late bool _teams = widget.initial.teams;
  late int _teamSize = widget.initial.teamSize;
  late bool _autoDraw = widget.initial.autoDraw;
  late bool _hideHand = widget.initial.hideHand;
  late bool _timerOn = widget.initial.timerSeconds >= minTimerSeconds;
  late final _timer = TextEditingController(
    text: widget.initial.timerSeconds >= minTimerSeconds
        ? '${widget.initial.timerSeconds}'
        : '30',
  );
  String? _error;

  @override
  void dispose() {
    _score.dispose();
    _timer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('إعدادات ألف ميل'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _score,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'حد نقاط المباراة (١٠٠٠–٥٠٠٠٠٠)',
              ),
            ),
            SwitchListTile(
              value: _stack,
              onChanged: (v) => setState(() => _stack = v),
              title: const Text('مراكمة الأعطال'),
              subtitle: const Text('السماح بمهاجمة السيارة الواقفة'),
            ),
            SwitchListTile(
              value: _reshuffle,
              onChanged: (v) => setState(() => _reshuffle = v),
              title: const Text('إعادة خلط أوراق المرمى عند نفاد الكومة'),
              subtitle: const Text('الحصانات لا تعود'),
            ),
            SwitchListTile(
              value: _teams,
              onChanged: (v) => setState(() => _teams = v),
              title: const Text('اللعب بفرق'),
              subtitle: const Text(
                '٤ أو ٦ أو ٨ أو ٩ لاعبين، سيارة واحدة لكل فريق',
              ),
            ),
            if (_teams)
              RadioGroup<int>(
                groupValue: _teamSize,
                onChanged: (v) => setState(() => _teamSize = v ?? _teamSize),
                child: const Column(
                  children: [
                    RadioListTile<int>(
                      value: 2,
                      title: Text('فريق من لاعبَين'),
                      subtitle: Text('٤ أو ٦ أو ٨ لاعبين'),
                    ),
                    RadioListTile<int>(
                      value: 3,
                      title: Text('فريق من ثلاثة'),
                      subtitle: Text('٦ أو ٩ لاعبين'),
                    ),
                    RadioListTile<int>(
                      value: 4,
                      title: Text('فريق من أربعة'),
                      subtitle: Text('٨ لاعبين'),
                    ),
                  ],
                ),
              ),
            SwitchListTile(
              value: _autoDraw,
              onChanged: (v) => setState(() => _autoDraw = v),
              title: const Text('سحب ورقة تلقائيًا'),
            ),
            SwitchListTile(
              value: _hideHand,
              onChanged: (v) => setState(() => _hideHand = v),
              title: const Text('إخفاء أوراقي'),
              subtitle: const Text(
                'تُقرأ كل ورقة كورقة مخفية عدا آخر ورقة مسحوبة',
              ),
            ),
            SwitchListTile(
              value: _timerOn,
              onChanged: (v) => setState(() => _timerOn = v),
              title: const Text('تفعيل مؤقت الدور'),
            ),
            if (_timerOn)
              TextField(
                controller: _timer,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                  labelText: 'مدة مؤقت الدور بالثواني',
                  errorText: _error,
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('إلغاء'),
        ),
        TextButton(
          onPressed: () {
            final score = int.tryParse(_score.text.trim()) ?? 5000;
            var timer = 0;
            if (_timerOn) {
              final value = int.tryParse(_timer.text.trim());
              if (value == null || value < minTimerSeconds) {
                setState(() => _error = timerError);
                return;
              }
              timer = value;
            }
            Navigator.of(context).pop(
              MilesSettings(
                scoreLimit: score.clamp(milesScoreMin, milesScoreMax),
                stackHazards: _stack,
                reshuffleDiscard: _reshuffle,
                teams: _teams,
                teamSize: _teamSize,
                autoDraw: _autoDraw,
                hideHand: _hideHand,
                timerSeconds: timer,
              ),
            );
          },
          child: const Text('تأكيد وبدء'),
        ),
      ],
    );
  }
}

class _LogSheet extends StatefulWidget {
  const _LogSheet({
    required this.entries,
    required this.privateMessages,
    required this.recipients,
    required this.me,
    required this.privateEnabled,
    required this.controller,
    required this.privateController,
    required this.onSend,
    required this.onSendPrivate,
  });

  final ValueListenable<List<TableLogEntry>> entries;
  final ValueListenable<List<PrivateMessage>> privateMessages;
  final List<Seat> recipients;
  final String me;
  final bool privateEnabled;
  final TextEditingController controller;
  final TextEditingController privateController;
  final Future<void> Function(String text) onSend;
  final Future<String?> Function(Seat to, String text) onSendPrivate;

  @override
  State<_LogSheet> createState() => _LogSheetState();
}

class _LogSheetState extends State<_LogSheet>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs;
  Seat? _to;
  String? _error;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 3, vsync: this);
    _to = widget.recipients.isEmpty ? null : widget.recipients.first;
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  Widget _list(List<String> lines, String empty) {
    if (lines.isEmpty) {
      return Center(child: Text(empty));
    }
    return ListView.builder(
      itemCount: lines.length,
      itemBuilder: (context, index) =>
          ListTile(dense: true, title: Text(lines[index])),
    );
  }

  Future<void> _sendPublic() async {
    final text = widget.controller.text.trim();
    if (text.isEmpty) {
      return;
    }
    widget.controller.clear();
    await widget.onSend(text);
  }

  Future<void> _sendPrivate() async {
    final text = widget.privateController.text.trim();
    final to = _to;
    if (text.isEmpty || to == null) {
      return;
    }
    widget.privateController.clear();
    final error = await widget.onSendPrivate(to, text);
    if (mounted) {
      setState(() => _error = error);
    }
  }

  @override
  Widget build(BuildContext context) {
    final height = MediaQuery.sizeOf(context).height * 0.75;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SafeArea(
        child: SizedBox(
          height: height,
          child: Column(
            children: [
              const Padding(
                padding: EdgeInsets.all(12),
                child: Text(
                  'السجل',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
              ),
              TabBar(
                controller: _tabs,
                tabs: const [
                  Tab(text: 'الأحداث'),
                  Tab(text: 'الدردشة العامة'),
                  Tab(text: 'الرسائل الخاصة'),
                ],
              ),
              Expanded(
                child: TabBarView(
                  controller: _tabs,
                  children: [
                    ValueListenableBuilder<List<TableLogEntry>>(
                      valueListenable: widget.entries,
                      builder: (context, entries, _) => _list([
                        for (final e in entries)
                          if (e.kind != 'chat') e.text,
                      ], 'لا توجد أحداث بعد'),
                    ),
                    Column(
                      children: [
                        Expanded(
                          child: ValueListenableBuilder<List<TableLogEntry>>(
                            valueListenable: widget.entries,
                            builder: (context, entries, _) => _list([
                              for (final e in entries)
                                if (e.kind == 'chat') e.text,
                            ], 'لا توجد رسائل عامة بعد'),
                          ),
                        ),
                        _inputRow(
                          controller: widget.controller,
                          label: 'رسالة عامة للطاولة',
                          onSend: _sendPublic,
                        ),
                      ],
                    ),
                    Column(
                      children: [
                        Expanded(
                          child: ValueListenableBuilder<List<PrivateMessage>>(
                            valueListenable: widget.privateMessages,
                            builder: (context, list, _) => _list([
                              for (final m in list)
                                m.fromUid == widget.me
                                    ? m.text
                                    : 'من ${m.fromName}: ${m.text}',
                            ], 'لا توجد رسائل خاصة'),
                          ),
                        ),
                        if (!widget.privateEnabled)
                          const Padding(
                            padding: EdgeInsets.all(12),
                            child: Text(
                              'الرسائل الخاصة تحتاج تسجيل الدخول والاتصال',
                            ),
                          )
                        else if (widget.recipients.isEmpty)
                          const Padding(
                            padding: EdgeInsets.all(12),
                            child: Text('لا يوجد لاعب آخر على الطاولة'),
                          )
                        else ...[
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 12),
                            child: DropdownButton<Seat>(
                              isExpanded: true,
                              value: _to,
                              hint: const Text('إلى'),
                              items: [
                                for (final seat in widget.recipients)
                                  DropdownMenuItem(
                                    value: seat,
                                    child: Text('إلى ${seat.name}'),
                                  ),
                              ],
                              onChanged: (seat) => setState(() => _to = seat),
                            ),
                          ),
                          if (_error != null)
                            Text(
                              _error!,
                              style: const TextStyle(color: Color(0xFFFFB4AB)),
                            ),
                          _inputRow(
                            controller: widget.privateController,
                            label: 'رسالة خاصة',
                            onSend: _sendPrivate,
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _inputRow({
    required TextEditingController controller,
    required String label,
    required Future<void> Function() onSend,
  }) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: controller,
              textDirection: TextDirection.rtl,
              decoration: InputDecoration(labelText: label),
              onSubmitted: (_) => onSend(),
            ),
          ),
          IconButton(
            tooltip: 'إرسال',
            onPressed: onSend,
            icon: const Icon(Icons.send),
          ),
        ],
      ),
    );
  }
}
