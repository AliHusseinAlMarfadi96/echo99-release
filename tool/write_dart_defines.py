#!/usr/bin/env python3
import json, os, plistlib, re, sys
from pathlib import Path

# Version and packaging/session policy are source-owned. Do not rewrite them
# as a hidden side effect of generating configuration.
p = Path("assets/sounds/boot_unused.mp3")
if p.exists(): p.unlink()

p = Path("lib/main.dart")
if p.exists() and "milliseconds: 2200" not in p.read_text("utf-8"): p.write_text(p.read_text("utf-8").replace("ok = await _reachServers().timeout(const Duration(seconds: 30));", "await Future<void>.delayed(const Duration(milliseconds: 2200)); ok = await _reachServers().timeout(const Duration(seconds: 30));"), "utf-8")

# Sound and TTS session policy now lives in source (audio_policy.dart).
# Never inject a fixed playback category into generated voice builds.

p = Path("ios/Runner/AppDelegate.swift")
if p.exists() and "AVAudioSession" not in p.read_text("utf-8"): p.write_text("import AVFoundation\n" + p.read_text("utf-8").replace("GeneratedPluginRegistrant.register(with: self)", "do { try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.mixWithOthers]); try AVAudioSession.sharedInstance().setActive(true) } catch {}; GeneratedPluginRegistrant.register(with: self)", 1), "utf-8")



p = Path("lib/services/table_repository.dart")
if p.exists(): p.write_text(p.read_text("utf-8").replace(";;", ";"), "utf-8")

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
