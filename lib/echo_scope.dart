import 'package:flutter/widgets.dart';

import 'services/account.dart';
import 'services/presence.dart';
import 'services/settings_model.dart';
import 'services/social_repository.dart';
import 'services/sounds.dart';
import 'services/speech.dart';
import 'services/table_repository.dart';
import 'services/voice_authority.dart';
import 'services/voice_room.dart';

class EchoScope extends InheritedWidget {
  const EchoScope({
    super.key,
    required this.settings,
    required this.account,
    required this.repo,
    required this.social,
    required this.sounds,
    required this.speech,
    required this.voice,
    this.voiceAuthority,
    required this.presence,
    required super.child,
  });

  final SettingsModel settings;
  final AccountController account;
  final TableRepository? repo;
  final SocialRepository? social;
  final SoundBoard sounds;
  final Speech speech;
  final VoiceRoom voice;

  /// Null until Firebase is ready: voice authority writes are skipped, the
  /// rules stay the enforcement boundary.
  final VoiceAuthority? voiceAuthority;
  final PresenceService presence;

  static EchoScope of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<EchoScope>();
    assert(scope != null, 'EchoScope missing');
    return scope!;
  }

  @override
  bool updateShouldNotify(EchoScope oldWidget) => true;
}
