#!/usr/bin/env bash
# Turn an unsigned Flutter iphoneos Runner.app into an ad-hoc IPA compatible with TrollStore and Sideloadly.
set -euo pipefail

APP="${1:-build/ios/iphoneos/Runner.app}"
OUT="${2:-Echo99.ipa}"

if [[ ! -d "$APP" ]]; then
  echo "Runner.app not found: $APP" >&2
  exit 1
fi

SOUNDS_DIR="$APP/Frameworks/App.framework/flutter_assets/assets/sounds"
if command -v ffmpeg >/dev/null 2>&1 && [[ -d "$SOUNDS_DIR" ]]; then
  ffmpeg -y -v error -ss 0.79 -to 1.80 -i "$SOUNDS_DIR/snakes/snake.mp3" -af "afade=t=in:st=0.79:d=0.02,afade=t=out:st=1.75:d=0.05" -ac 1 -ar 44100 -b:a 128k /tmp/snake.mp3 && mv /tmp/snake.mp3 "$SOUNDS_DIR/snakes/snake.mp3" || true
  ffmpeg -y -v error -ss 0.11 -to 0.95 -i "$SOUNDS_DIR/snakes/dice_roll.mp3" -af "afade=t=in:st=0.11:d=0.01,afade=t=out:st=0.91:d=0.04" -ac 1 -ar 44100 -b:a 128k /tmp/dice_roll.mp3 && mv /tmp/dice_roll.mp3 "$SOUNDS_DIR/dice_roll.mp3" || true
  ffmpeg -y -v error -ss 0.00 -to 0.18 -i "$SOUNDS_DIR/snakes/step.mp3" -af "afade=t=out:st=0.14:d=0.04" -ac 1 -ar 44100 -b:a 128k /tmp/step.mp3 && mv /tmp/step.mp3 "$SOUNDS_DIR/snakes/step.mp3" || true
  ffmpeg -y -v error -ss 0.03 -to 0.40 -i "$SOUNDS_DIR/snakes/ladder.mp3" -af "afade=t=in:st=0.03:d=0.01,afade=t=out:st=0.36:d=0.04" -ac 1 -ar 44100 -b:a 128k /tmp/ladder.mp3 && mv /tmp/ladder.mp3 "$SOUNDS_DIR/snakes/ladder.mp3" || true
  ffmpeg -y -v error -ss 0.00 -to 0.80 -i "$SOUNDS_DIR/jk_burn_cards.mp3" -ac 1 -ar 44100 -b:a 128k /tmp/jk_burn_cards.mp3 && mv /tmp/jk_burn_cards.mp3 "$SOUNDS_DIR/jk_burn_cards.mp3" || true
fi

python3 - "$APP" << 'PY'
import os, sys, struct, shutil, plistlib

app = sys.argv[1]

def iter_macho(root):
    for dirpath, dirs, files in os.walk(root):
        for fn in files:
            path = os.path.join(dirpath, fn)
            if os.path.islink(path) or not os.path.isfile(path):
                continue
            if os.path.getsize(path) < 64:
                continue
            with open(path, "rb") as fh:
                magic = fh.read(4)
            if magic in (b"\xcf\xfa\xed\xfe", b"\xca\xfe\xba\xbe", b"\xfe\xed\xfa\xcf", b"\xce\xfa\xed\xfe"):
                yield path

def slices(path):
    with open(path, "rb") as fh:
        magic = fh.read(4)
        fh.seek(0)
        if magic == b"\xca\xfe\xba\xbe":
            nfat = struct.unpack(">I", fh.read(8)[4:])[0]
            offsets = []
            for _ in range(nfat):
                _cpu, _sub, offset, _size, _align = struct.unpack(">IIIII", fh.read(20))
                offsets.append(offset)
            out = []
            for offset in offsets:
                fh.seek(offset)
                mh = fh.read(32)
                if len(mh) < 32 or struct.unpack_from("<I", mh, 0)[0] != 0xFEEDFACF:
                    continue
                ncmds, sizeofcmds = struct.unpack_from("<II", mh, 16)
                out.append(mh + fh.read(sizeofcmds))
            return out
        if magic == b"\xcf\xfa\xed\xfe":
            mh = fh.read(32)
            ncmds, sizeofcmds = struct.unpack_from("<II", mh, 16)
            return [mh + fh.read(sizeofcmds)]
    return []

def walk_cmds(buf):
    o = 32
    while o + 8 <= len(buf):
        cmd, cmdsize = struct.unpack_from("<II", buf, o)
        if cmdsize < 8 or o + cmdsize > len(buf):
            break
        yield cmd, buf[o:o + cmdsize]
        o += cmdsize

def cmd_name(blob):
    nameoff = struct.unpack_from("<I", blob, 8)[0]
    return blob[nameoff:].split(b"\x00", 1)[0].decode("utf-8", "replace")

referenced = {"App", "Flutter"}
for path in iter_macho(app):
    for buf in slices(path):
        for cmd, blob in walk_cmds(buf):
            if cmd in (0xC, 0x18) and b".framework/" in blob:
                name = cmd_name(blob)
                fw = name.split(".framework/")[0].split("/")[-1]
                referenced.add(fw)

frameworks = os.path.join(app, "Frameworks")
if os.path.isdir(frameworks):
    for entry in sorted(os.listdir(frameworks)):
        if not entry.endswith(".framework"):
            continue
        fw_name = entry[: -len(".framework")]
        fw_path = os.path.join(frameworks, entry)
        if fw_name not in referenced:
            shutil.rmtree(fw_path)
            print(f"removed unreferenced framework {entry}")

for dirpath, dirs, files in os.walk(app):
    for fn in files:
        if fn != "Info.plist":
            continue
        p = os.path.join(dirpath, fn)
        try:
            with open(p, "rb") as fh:
                pl = plistlib.load(fh)
        except Exception:
            continue
        if not isinstance(pl, dict):
            continue
        changed = False
        if dirpath == app:
            if pl.get("MinimumOSVersion") != "14.0":
                pl["MinimumOSVersion"] = "14.0"
                changed = True
            if "UIDeviceFamily" not in pl:
                pl["UIDeviceFamily"] = [1, 2]
                changed = True
        elif dirpath.endswith(".framework"):
            if pl.get("CFBundlePackageType") != "FMWK":
                pl["CFBundlePackageType"] = "FMWK"
                changed = True
            bid = str(pl.get("CFBundleIdentifier", ""))
            if "_" in bid:
                pl["CFBundleIdentifier"] = bid.replace("_", "-")
                changed = True
        elif dirpath.endswith(".bundle"):
            if "CFBundleExecutable" in pl:
                del pl["CFBundleExecutable"]
                changed = True
        if changed:
            with open(p, "wb") as fh:
                plistlib.dump(pl, fh, fmt=plistlib.PlistFormat.FMT_XML)
            print(f"normalized {os.path.relpath(p, app)}")
PY

xattr -cr "$APP" || true

sign_framework() {
  codesign --force --sign - --timestamp=none "$1"
}

sign_app() {
  codesign --force --sign - --timestamp=none "$1"
}

find "$APP/Frameworks" -mindepth 1 -maxdepth 1 -name '*.framework' -print0 | while IFS= read -r -d '' fw; do
  sign_framework "$fw"
done

sign_app "$APP"

PAYLOAD="$(mktemp -d)"
trap 'rm -rf "$PAYLOAD"' EXIT

mkdir -p "$PAYLOAD/Payload"
cp -RP "$APP" "$PAYLOAD/Payload/"

OUT_ABS="$(cd "$(dirname "$OUT")" && pwd)/$(basename "$OUT")"
rm -f "$OUT_ABS"
(cd "$PAYLOAD" && zip -q -r -y "$OUT_ABS" Payload)

echo "Wrote $OUT_ABS"
