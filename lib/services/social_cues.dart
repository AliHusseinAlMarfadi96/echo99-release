import 'dart:async';

import 'package:flutter/material.dart';

import '../echo_scope.dart';
import 'doc_id.dart';
import 'presence.dart';

/// Plays friend, invite, request, and private-message sounds after the
/// first snapshot so opening the app does not replay history.
class SocialCueListener extends StatefulWidget {
  const SocialCueListener({
    super.key,
    required this.enabled,
    required this.child,
  });

  final bool enabled;
  final Widget child;

  @override
  State<SocialCueListener> createState() => _SocialCueListenerState();
}

class _SocialCueListenerState extends State<SocialCueListener> {
  final List<StreamSubscription<dynamic>> _subs = [];
  String? _uid;
  var _friendsSeen = false;
  var _onlineSeen = false;
  var _presenceReady = false;
  List<String> _friendIds = const [];
  Set<String> _online = {};
  Set<String> _friendOnline = {};
  var _inviteReady = false;
  Set<String> _invites = {};
  var _requestReady = false;
  Set<String> _requests = {};
  var _mailReady = false;
  Set<String> _mail = {};

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _bind();
  }

  @override
  void didUpdateWidget(covariant SocialCueListener oldWidget) {
    super.didUpdateWidget(oldWidget);
    _bind();
  }

  void _bind() {
    final scope = EchoScope.of(context);
    final social = scope.social;
    final uid = scope.settings.playerId;
    if (!widget.enabled || social == null || !isSafeDocId(uid)) {
      _stop();
      return;
    }
    if (_uid == uid && _subs.isNotEmpty) {
      return;
    }
    _stop();
    _uid = uid;
    _subs
      ..add(
        social.watchFriends(uid).listen((friends) {
          _friendIds = [for (final friend in friends) friend.uid];
          _friendsSeen = true;
          _presence();
        }, onError: (_) {}),
      )
      ..add(
        onlinePlayers(
          presence: scope.presence,
          firestore: social.watchOnline,
        ).listen((people) {
          _online = {for (final player in people) player.uid};
          _onlineSeen = true;
          _presence();
        }, onError: (_) {}),
      )
      ..add(
        social.watchInvites(uid).listen((invites) {
          final ids = {for (final invite in invites) invite.id};
          if (!_inviteReady) {
            _inviteReady = true;
            _invites = ids;
            return;
          }
          if (ids.difference(_invites).isNotEmpty && mounted) {
            EchoScope.of(context).sounds.play('invite');
          }
          _invites = ids;
        }, onError: (_) {}),
      )
      ..add(
        social.watchFriendRequests(uid).listen((ids) {
          if (!_requestReady) {
            _requestReady = true;
            _requests = ids;
            return;
          }
          if (ids.difference(_requests).isNotEmpty && mounted) {
            EchoScope.of(context).sounds.play('friend_request');
          }
          _requests = ids;
        }, onError: (_) {}),
      )
      ..add(
        social.watchPrivateMessages(uid).listen((ids) {
          if (!_mailReady) {
            _mailReady = true;
            _mail = ids;
            return;
          }
          if (ids.difference(_mail).isNotEmpty && mounted) {
            EchoScope.of(context).sounds.play('dm');
          }
          _mail = ids;
        }, onError: (_) {}),
      );
  }

  void _presence() {
    if (!_friendsSeen || !_onlineSeen || !mounted) {
      return;
    }
    final now = {
      for (final id in _friendIds)
        if (_online.contains(id)) id,
    };
    if (!_presenceReady) {
      _presenceReady = true;
      _friendOnline = now;
      return;
    }
    final sounds = EchoScope.of(context).sounds;
    if (now.difference(_friendOnline).isNotEmpty) {
      sounds.play('friend_on');
    }
    if (_friendOnline.difference(now).isNotEmpty) {
      sounds.play('friend_off');
    }
    _friendOnline = now;
  }

  void _stop() {
    for (final sub in _subs) {
      sub.cancel();
    }
    _subs.clear();
    _uid = null;
    _friendsSeen = false;
    _onlineSeen = false;
    _presenceReady = false;
    _friendIds = const [];
    _online = {};
    _friendOnline = {};
    _inviteReady = false;
    _invites = {};
    _requestReady = false;
    _requests = {};
    _mailReady = false;
    _mail = {};
  }

  @override
  void dispose() {
    _stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
