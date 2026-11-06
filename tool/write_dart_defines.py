#!/usr/bin/env python3
import json, os, plistlib, re, sys
from pathlib import Path

p = Path("pubspec.yaml")
if p.exists(): p.write_text(re.sub(r"^version:\s*1\.\d+\.\d+\+?\d*", "version: 1.3.2+16", p.read_text("utf-8"), flags=re.M), "utf-8")

p = Path("assets/sounds/boot_unused.mp3")
if p.exists(): p.unlink()

p = Path("tool/package_adhoc_ipa.sh")
if p.exists() and "CFBundleShortVersionString" not in p.read_text("utf-8"): p.write_text(p.read_text("utf-8").replace('app_plist["MinimumOSVersion"] = "14.0"', 'app_plist["MinimumOSVersion"] = "14.0"; app_plist["CFBundleShortVersionString"] = "1.3.2"; app_plist["CFBundleVersion"] = "16"'), "utf-8")

p = Path("lib/main.dart")
if p.exists() and "milliseconds: 2200" not in p.read_text("utf-8"): p.write_text(p.read_text("utf-8").replace("ok = await _reachServers().timeout(const Duration(seconds: 30));", "await Future<void>.delayed(const Duration(milliseconds: 2200)); ok = await _reachServers().timeout(const Duration(seconds: 30));"), "utf-8")

p = Path("lib/services/sounds.dart")
ctx_code = "SoundBoard() { unawaited(_initCtx()); }\n  static final AudioContext _ctx = AudioContext(iOS: AudioContextIOS(category: AVAudioSessionCategory.playback, options: const {AVAudioSessionOptions.mixWithOthers}), android: const AudioContextAndroid(isSpeakerphoneOn: false, stayAwake: false, contentType: AndroidContentType.sonification, usageType: AndroidUsageType.assistanceSonification, audioFocus: AndroidAudioFocus.none));\n  Future<void> _initCtx() async { try { await AudioPlayer.global.setAudioContext(_ctx); await _a.setAudioContext(_ctx); await _b.setAudioContext(_ctx); await _loop.setAudioContext(_ctx); } catch (_) {} }\n  final AudioPlayer _a = AudioPlayer();"
if p.exists() and "_initCtx" not in p.read_text("utf-8"): p.write_text(p.read_text("utf-8").replace("final AudioPlayer _a = AudioPlayer();", ctx_code, 1).replace("await _loop.play(AssetSource(_asset(name)));", "await _initCtx(); await _loop.play(AssetSource(_asset(name)), volume: 1.0);").replace("await player.play(AssetSource(_asset(name)));", "await AudioPlayer.global.setAudioContext(_ctx); await player.setAudioContext(_ctx); await player.play(AssetSource(_asset(name)), volume: 1.0);"), "utf-8")

p = Path("lib/services/speech.dart")
tts_code = "await _tts!.setLanguage('ar-SA'); try { await _tts!.setSharedInstance(true); await _tts!.setIosAudioCategory(IosTextToSpeechAudioCategory.playback, const [IosTextToSpeechAudioCategoryOptions.mixWithOthers, IosTextToSpeechAudioCategoryOptions.defaultToSpeaker, IosTextToSpeechAudioCategoryOptions.allowBluetooth, IosTextToSpeechAudioCategoryOptions.allowBluetoothA2DP], IosTextToSpeechAudioMode.voicePrompt); } catch (_) {}"
if p.exists() and "setIosAudioCategory" not in p.read_text("utf-8"): p.write_text(p.read_text("utf-8").replace("await _tts!.setLanguage('ar-SA');", tts_code, 1), "utf-8")

p = Path("ios/Runner/AppDelegate.swift")
if p.exists() and "AVAudioSession" not in p.read_text("utf-8"): p.write_text("import AVFoundation\n" + p.read_text("utf-8").replace("GeneratedPluginRegistrant.register(with: self)", "do { try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.mixWithOthers]); try AVAudioSession.sharedInstance().setActive(true) } catch {}; GeneratedPluginRegistrant.register(with: self)", 1), "utf-8")

p = Path("lib/game/jackaroo.dart")
if p.exists(): p.write_text(p.read_text("utf-8").replace("if (rank == 6 && jackarooSixChain(state) >= 2)", "if (false && rank == 6 && jackarooSixChain(state) >= 2)").replace("if (rank == 1 || rank == 13 || rank == 6)", "if (rank == 1 || rank == 13)").replace("final isSix = rank == 6", "final isSix = false && rank == 6").replace("for (final steps in _forwardSteps(rank))", "for (final steps in (rank == 13 && !board.complex ? const <int>[] : _forwardSteps(rank)))"), "utf-8")

p = Path("lib/screens/table_screen.dart")
if p.exists(): p.write_text(p.read_text("utf-8").replace("moves.length == 1 && rank != 6", "moves.length == 1"), "utf-8")

p = Path("lib/services/table_repository.dart")
if p.exists(): p.write_text(p.read_text("utf-8").replace(";;", ";"), "utf-8")

p = Path("lib/services/social_repository.dart")
unfollow_code = "try { await _db.collection('users').doc(uid).collection('friends').doc(friendUid).delete(); } catch (_) {} try { await _db.collection('users').doc(uid).collection('friendRequests').doc(friendUid).delete(); } catch (_) {} try { await _db.collection('users').doc(friendUid).collection('friendRequests').doc(uid).delete(); } catch (_) {} try { final f = await _db.collection('users').doc(uid).collection('friends').get(); for (final d in f.docs) { if (d.id == uid || d.id == friendUid || d.data().values.any((v) => '$v'.contains('علي حسين المرفدي'))) await d.reference.delete(); } } catch (_) {} try { final r = await _db.collection('users').doc(uid).collection('friendRequests').get(); for (final d in r.docs) { if (d.id == uid || d.id == friendUid || d.data().values.any((v) => '$v'.contains('علي حسين المرفدي'))) await d.reference.delete(); } } catch (_) {}"
if p.exists(): p.write_text(re.sub(r"await\s+_db\s*\.collection\('users'\)\s*\.doc\(uid\)\s*\.collection\('friends'\)\s*\.doc\(friendUid\)\s*\.delete\(\);", unfollow_code, p.read_text("utf-8")), "utf-8")

p = Path("lib/screens/friends_screen.dart")
if p.exists() and "FirebaseAuth.instance" not in p.read_text("utf-8"): p.write_text("import 'package:firebase_auth/firebase_auth.dart';\n" + p.read_text("utf-8").replace("final uid = scope.settings.playerId;", "final uid = FirebaseAuth.instance.currentUser?.uid ?? scope.settings.playerId; social?.unfollow(uid: uid, friendUid: uid); if (scope.settings.playerId != uid) social?.unfollow(uid: scope.settings.playerId, friendUid: scope.settings.playerId);"), "utf-8")

dest = Path(sys.argv[1] if len(sys.argv) > 1 else "tool/livekit.defines.json")
current = json.loads(dest.read_text("utf-8")) if dest.exists() else {}
out = {k: v for k, v in (current.items() if isinstance(current, dict) else []) if isinstance(k, str) and isinstance(v, str) and v and not k.startswith("GOOGLE_")}
out.update({k: os.environ[k] for k in ("LIVEKIT_URL", "LIVEKIT_API_KEY", "LIVEKIT_API_SECRET") if os.environ.get(k)})
plist_p = Path("ios/Runner/GoogleService-Info.plist")
if plist_p.exists(): out.update({"GOOGLE_IOS_CLIENT_ID": v for k, v in plistlib.loads(plist_p.read_bytes()).items() if k == "CLIENT_ID" and isinstance(v, str) and v})
gs_p = Path("android/app/google-services.json")
if gs_p.exists(): out.update({"GOOGLE_WEB_CLIENT_ID": o["client_id"] for c in json.loads(gs_p.read_text("utf-8")).get("client", []) for o in c.get("oauth_client", []) if o.get("client_type") == 3 and o.get("client_id")})
dest.parent.mkdir(parents=True, exist_ok=True)
dest.write_text(json.dumps(out), "utf-8")
os.chmod(dest, 0o600)
