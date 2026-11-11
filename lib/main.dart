import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'echo_scope.dart';
import 'screens/create_table_screen.dart';
import 'screens/force_update_screen.dart';
import 'screens/friends_screen.dart';
import 'screens/join_screen.dart';
import 'screens/login_screen.dart';
import 'screens/menu_screen.dart';
import 'screens/online_screen.dart';
import 'screens/settings_screen.dart';
import 'services/account.dart';
import 'services/app_config.dart';
import 'services/doc_id.dart';
import 'services/firebase_boot.dart';
import 'services/presence.dart';
import 'services/server_link.dart';
import 'services/settings_model.dart';
import 'services/social_cues.dart';
import 'services/social_repository.dart';
import 'services/sounds.dart';
import 'services/startup_audio.dart';
import 'services/speech.dart';
import 'services/table_repository.dart';
import 'services/voice_authority.dart';
import 'services/voice_room.dart';
import 'services/voice_token_transport.dart';

/// Read-only startup timing for the 15-20s app-open wait: one debugPrint
/// per stage, no behavior, network, or UI change. Shared by main() and the
/// app widget so every stage reads off one clock.
final _bootWatch = Stopwatch()..start();
void _bootMark(String stage) {
  debugPrint('Echo99 boot probe: $stage @ ${_bootWatch.elapsedMilliseconds}ms');
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  _bootMark('binding');
  // Android/iOS start from the native google-services.json /
  // GoogleService-Info.plist; see bootFirebase for the fallback.
  final boot = await bootFirebase();
  _bootMark('firebase ready=${boot.ready}');
  final firebaseReady = boot.ready;
  final firebaseError = boot.error;
  final settings = await SettingsModel.load();
  _bootMark('settings');
  runApp(
    Echo99App(
      settings: settings,
      firebaseReady: firebaseReady,
      firebaseError: firebaseError,
    ),
  );
}

enum _Gate { boot, login, connecting, failed, menu }

class Echo99App extends StatefulWidget {
  const Echo99App({
    super.key,
    required this.settings,
    required this.firebaseReady,
    this.firebaseError,
  });

  final SettingsModel settings;
  final bool firebaseReady;
  final String? firebaseError;

  @override
  State<Echo99App> createState() => _Echo99AppState();
}

class _Echo99AppState extends State<Echo99App> with WidgetsBindingObserver {
  final _sounds = SoundBoard();
  late final _startupAudio = StartupAudio(
    start: () => _sounds.loop('ambient', repeat: false),
    stop: _sounds.stopLoop,
  );
  final _speech = Speech();
  final _voice = VoiceRoom();
  final _voiceTokens = VoiceTokenTransport.configured();
  final _presence = PresenceService();
  late final AccountController _account;
  TableRepository? _repo;
  SocialRepository? _social;
  VoiceAuthority? _voiceAuthority;
  int? _latencyMs;
  var _latencyFailed = false;
  var _configReady = false;
  var _update = AppUpdate.none;
  var _gate = _Gate.boot;
  var _offline = false;
  var _linking = false;

  /// Non-blocking note shown in the menu when LiveKit voice is unavailable.
  String? _voiceNote;
  var _voiceWarming = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_startupAudio.startOnce());
    });
    _voice.serverTokenCall = _voiceTokens.mint;
    _account = AccountController(
      widget.settings,
      firebaseReady: widget.firebaseReady,
      firebaseInitError: widget.firebaseError,
    );
    _attachFirebase();
    _account.addListener(_onAccount);
    _account.restore();
    _loadConfig();
  }

  bool get _firebaseReady => _account.firebaseReady;

  /// Creates the Firestore repositories once Firebase is up (at launch, or
  /// later when a Google tap re-runs a failed init).
  void _attachFirebase() {
    if (!_account.firebaseReady || _repo != null) {
      return;
    }
    _repo = TableRepository();
    _social = SocialRepository();
    _voiceAuthority = VoiceAuthority(
      FirebaseFirestore.instance,
      transport: _voiceTokens,
    );
  }

  Future<void> _loadConfig() async {
    if (_firebaseReady) {
      _bootMark('config load start');
      _update = await AppConfigRepository().load();
      _bootMark('config loaded');
    }
    if (!mounted) {
      return;
    }
    setState(() => _configReady = true);
    _syncGate();
  }

  void _onAccount() {
    _attachFirebase();
    if (!_account.signedIn) {
      _offline = false;
      _linking = false;
      // Initial login keeps the one startup clip. A real sign-out ends it.
      if (_gate == _Gate.menu || _gate == _Gate.connecting) {
        unawaited(_startupAudio.finish());
      }
      _voice.close();
      unawaited(_presence.goOffline());
    }
    _syncGate();
    setState(() {});
  }

  void _syncGate() {
    if (!_account.ready || !_configReady) {
      _gate = _Gate.boot;
      return;
    }
    if (_update.required) {
      _gate = _Gate.boot;
      return;
    }
    if (!_account.signedIn) {
      _offline = false;
      _linking = false;
      _gate = _Gate.login;
      return;
    }
    if (_account.guest) {
      _offline = true;
      _linking = false;
      // Offline guests hear the same one-shot launch clip, not a server chime.
      if (_gate != _Gate.menu) {
        _gate = _Gate.menu;
      }
      return;
    }
    if (_gate == _Gate.menu ||
        _gate == _Gate.failed ||
        _gate == _Gate.connecting) {
      return;
    }
    _gate = _Gate.connecting;
    _bootMark('gate->connecting signedIn=${_account.signedIn}');
    unawaited(_runLink());
  }

  Future<void> _runLink() async {
    if (_linking) {
      return;
    }
    _linking = true;
    // Reuse the startup clip at sign-in, never play it twice in parallel.
    // Guests hear startup but never enter the online connection gate.
    final audible = !_account.guest;
    if (mounted) {
      setState(() => _gate = _Gate.connecting);
    }
    if (audible) {
      await _startupAudio.connecting();
    }
    var ok = false;
    try {
      await Future<void>.delayed(const Duration(milliseconds: 2200));
      _bootMark('fixed delay done, probing');
      ok = await _reachServers().timeout(const Duration(seconds: 30));
      _bootMark('reachServers ok=$ok latencyMs=$_latencyMs');
    } catch (_) {
      ok = false;
    }
    await _startupAudio.finish();
    _linking = false;
    if (!mounted || !_account.signedIn || _account.guest || _update.required) {
      return;
    }
    if (ok) {
      if (audible) {
        await _sounds.play('connected');
      }
      if (!mounted) {
        return;
      }
      setState(() {
        _offline = false;
        _gate = _Gate.menu;
      });
      _markOnline(true);
      _bootMark('gate->menu');
      unawaited(_warmVoice());
      return;
    }
    if (audible) {
      await _sounds.play('error');
    }
    if (!mounted) {
      return;
    }
    setState(() => _gate = _Gate.failed);
  }

  /// Firestore is the required online server (tables, friends, presence).
  /// LiveKit voice is started afterwards by [_warmVoice] and never blocks.
  Future<bool> _reachServers() async {
    final social = _social;
    final uid = widget.settings.playerId;
    if (!_firebaseReady || social == null || !isSafeDocId(uid)) {
      return false;
    }
    final result = await reachTableServer(() => social.measureLatency(uid));
    if (!result.online) {
      debugPrint('Echo99 table server unreachable: ${result.error}');
      return false;
    }
    if (mounted) {
      setState(() {
        _latencyMs = result.latencyMs;
        _latencyFailed = false;
      });
    }
    return true;
  }

  /// Best-effort LiveKit lobby warmup with one retry. A failure only shows a
  /// non-blocking Arabic note; tables keep working through Firestore.
  Future<void> _warmVoice() async {
    if (_voiceWarming || _offline) {
      return;
    }
    _voiceWarming = true;
    final uid = widget.settings.playerId;
    final error = await warmVoiceBestEffort(() async {
      try {
        return await _voice.warmup(
          identity: uid,
          displayName: widget.settings.displayName,
        );
      } catch (_) {
        await _voice.close();
        rethrow;
      }
    });
    _voiceWarming = false;
    _bootMark('voice warmup done error=${error == null ? "no" : "yes"}');
    if (!mounted || _offline) {
      return;
    }
    if (error != null) {
      debugPrint('Echo99 voice unavailable (tables stay online).');
    }
    setState(() => _voiceNote = error == null ? null : voiceUnavailableNote);
  }

  Future<void> _chooseOffline() async {
    await _startupAudio.finish();
    await _voice.close();
    if (!mounted) {
      return;
    }
    setState(() {
      _offline = true;
      _gate = _Gate.menu;
      _latencyMs = null;
      _latencyFailed = true;
      _voiceNote = null;
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      unawaited(_startupAudio.finish());
    }
    if (state == AppLifecycleState.resumed) {
      unawaited(_onResume());
      return;
    }
    if (!_account.signedIn ||
        _account.guest ||
        _offline ||
        _gate != _Gate.menu) {
      return;
    }
    if (state == AppLifecycleState.detached) {
      // Process is going away: drop presence now instead of waiting for the
      // RTDB server to notice the dead socket.
      _markOnline(false);
      unawaited(_presence.goOffline());
    }
  }

  Future<void> _onResume() async {
    await _account.onResume();
    if (!mounted || !_account.signedIn) {
      return;
    }
    if (_account.guest || _offline) {
      return;
    }
    // Re-enter connecting-to-server so the ~30s ambient loop plays again.
    if (_gate == _Gate.menu || _gate == _Gate.failed) {
      setState(() => _gate = _Gate.connecting);
      unawaited(_runLink());
    }
  }

  void _markOnline(bool online) {
    if (_offline) {
      return;
    }
    final social = _social;
    final uid = widget.settings.playerId;
    if (social == null || !isSafeDocId(uid)) {
      return;
    }
    social.setOnline(
      uid: uid,
      name: widget.settings.displayName,
      online: online,
    );
    if (online) {
      unawaited(
        _presence.goOnline(uid: uid, name: widget.settings.displayName),
      );
    }
  }

  Future<void> _measureLatency() async {
    if (_offline) {
      setState(() {
        _latencyMs = null;
        _latencyFailed = true;
      });
      return;
    }
    final social = _social;
    final uid = widget.settings.playerId;
    if (social == null || !isSafeDocId(uid)) {
      setState(() {
        _latencyMs = null;
        _latencyFailed = true;
      });
      return;
    }
    try {
      final ms = await social.measureLatency(uid);
      if (!mounted) {
        return;
      }
      setState(() {
        _latencyMs = ms;
        _latencyFailed = false;
      });
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() {
        _latencyMs = null;
        _latencyFailed = true;
      });
    }
  }

  String get _latencyLabel {
    final ms = _latencyMs;
    if (ms != null) {
      return 'زمن الاستجابة · $ms مللي ثانية';
    }
    if (_latencyFailed) {
      return 'زمن الاستجابة · غير متاح';
    }
    return 'زمن الاستجابة';
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _account.removeListener(_onAccount);
    _markOnline(false);
    unawaited(_startupAudio.close());
    _sounds.dispose();
    _voice.close();
    unawaited(_presence.goOffline());
    _account.dispose();
    widget.settings.dispose();
    _voiceTokens.close();
    super.dispose();
  }

  Widget _home() {
    if (_update.required && _configReady) {
      return ForceUpdateScreen(
        androidUrl: _update.androidUrl,
        iosUrl: _update.iosUrl,
      );
    }
    if (!_account.ready || !_configReady || _gate == _Gate.boot) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (_gate == _Gate.login || !_account.signedIn) {
      return LoginScreen(
        busy: _account.busy,
        error: _account.error,
        onGoogle: _account.signInWithGoogle,
        onGuest: _account.continueAsGuest,
      );
    }
    if (_gate == _Gate.connecting) {
      return Scaffold(
        body: Center(
          child: Semantics(
            liveRegion: true,
            textDirection: TextDirection.rtl,
            child: const Text(
              'جارٍ الاتصال بالسيرفر',
              textDirection: TextDirection.rtl,
            ),
          ),
        ),
      );
    }
    if (_gate == _Gate.failed) {
      return _LinkFailed(onRetry: _runLink, onOffline: _chooseOffline);
    }
    return _Menu(
      latencyLabel: _latencyLabel,
      onLatency: _measureLatency,
      offline: _offline,
      voiceNote: _offline ? null : _voiceNote,
      onRetryVoice: _warmVoice,
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.settings,
      builder: (context, _) {
        return EchoScope(
          settings: widget.settings,
          account: _account,
          repo: _repo,
          social: _social,
          sounds: _sounds,
          speech: _speech,
          voice: _voice,
          voiceAuthority: _voiceAuthority,
          presence: _presence,
          child: SocialCueListener(
            enabled:
                _gate == _Gate.menu &&
                _account.signedIn &&
                !_account.guest &&
                !_offline,
            child: MaterialApp(
              title: 'Echo99',
              debugShowCheckedModeBanner: false,
              locale: const Locale('ar'),
              localizationsDelegates: GlobalMaterialLocalizations.delegates,
              supportedLocales: const [Locale('ar')],
              theme: ThemeData(
                useMaterial3: true,
                brightness: Brightness.dark,
                scaffoldBackgroundColor: const Color(0xFF10241C),
                colorScheme: const ColorScheme.dark(
                  primary: Color(0xFFE8C872),
                  surface: Color(0xFF163528),
                  onSurface: Color(0xFFF8F1DE),
                ),
              ),
              builder: (context, child) => Directionality(
                textDirection: TextDirection.rtl,
                child: Semantics(
                  textDirection: TextDirection.rtl,
                  child: child ?? const SizedBox.shrink(),
                ),
              ),
              home: _home(),
            ),
          ),
        );
      },
    );
  }
}

class _LinkFailed extends StatelessWidget {
  const _LinkFailed({required this.onRetry, required this.onOffline});

  final VoidCallback onRetry;
  final VoidCallback onOffline;

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      child: Scaffold(
        body: SafeArea(
          child: Center(
            child: Semantics(
              namesRoute: true,
              label: 'فشل الاتصال بالسيرفر. هل تريد إعادة المحاولة أو اللعب بدون إنترنت؟',
              child: AlertDialog(
                content: const Text(
                  'فشل الاتصال بالسيرفر. هل تريد إعادة المحاولة أو اللعب بدون إنترنت؟',
                ),
                actions: [
                  Semantics(
                    button: true,
                    label: 'إعادة المحاولة',
                    textDirection: TextDirection.rtl,
                    child: ExcludeSemantics(
                      child: TextButton(
                        onPressed: onRetry,
                        child: const Text(
                          'إعادة المحاولة',
                          textDirection: TextDirection.rtl,
                        ),
                      ),
                    ),
                  ),
                  Semantics(
                    button: true,
                    label: 'لعب بدون إنترنت',
                    textDirection: TextDirection.rtl,
                    child: ExcludeSemantics(
                      child: TextButton(
                        onPressed: onOffline,
                        child: const Text(
                          'لعب بدون إنترنت',
                          textDirection: TextDirection.rtl,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Menu extends StatelessWidget {
  const _Menu({
    required this.latencyLabel,
    required this.onLatency,
    required this.offline,
    this.voiceNote,
    this.onRetryVoice,
  });

  final String latencyLabel;
  final VoidCallback onLatency;
  final bool offline;
  final String? voiceNote;
  final VoidCallback? onRetryVoice;

  @override
  Widget build(BuildContext context) {
    return MenuScreen(
      latencyLabel: latencyLabel,
      onLatency: onLatency,
      notice: voiceNote,
      onNotice: onRetryVoice,
      noticeAction: voiceRetryLabel,
      onCreate: () {
        // Popup: جاكارو، لودو، السلم والثعبان، 99، ألف ميل.
        unawaited(showCreateTableDialog(context, offline: offline));
      },
      onJoin: () {
        if (offline) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('اللعب بدون إنترنت متاح ضد البوت فقط'),
            ),
          );
          return;
        }
        Navigator.of(context)
            .push(MaterialPageRoute(builder: (_) => const JoinScreen()));
      },
      onSettings: () {
        Navigator.of(context)
            .push(MaterialPageRoute(builder: (_) => const SettingsScreen()));
      },
      onOnline: () {
        Navigator.of(context)
            .push(MaterialPageRoute(builder: (_) => const OnlineScreen()));
      },
      onFriends: () {
        Navigator.of(context)
            .push(MaterialPageRoute(builder: (_) => const FriendsScreen()));
      },
    );
  }
}
