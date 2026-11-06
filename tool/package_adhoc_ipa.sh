#!/usr/bin/env bash
# Turn an unsigned Flutter iphoneos Runner.app into an ad-hoc IPA compatible with TrollStore and Sideloadly.
set -euo pipefail

APP="${1:-build/ios/iphoneos/Runner.app}"
OUT="${2:-Echo99.ipa}"

if [[ ! -d "$APP" ]]; then
  echo "Runner.app not found: $APP" >&2
  exit 1
fi

# Preserve supplied sound assets byte-for-byte; no packaging-time trims.

python3 - "$APP" << 'PY'
import os, sys, struct, plistlib

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

# Flutter native assets are loaded by Dart FFI, not LC_LOAD_DYLIB. Never
# prune build-produced frameworks based only on Mach-O linkage.
import json
from pathlib import Path
root = Path(app)
frameworks = root / 'Frameworks'
for manifest in root.rglob('NativeAssetsManifest.json'):
    data = json.loads(manifest.read_text())
    for target, assets in data.get('native-assets', {}).items():
        for asset_id, spec in assets.items():
            if not isinstance(spec, list) or not spec:
                raise SystemExit(f'Invalid native asset entry: {asset_id}')
            if spec[0] in ('process', 'executable', 'system'):
                continue
            if len(spec) < 2:
                raise SystemExit(f'Missing native asset path: {asset_id}')
            rel = Path(spec[1])
            if rel.is_absolute() or '..' in rel.parts:
                raise SystemExit(f'Unsafe native asset path: {asset_id}')
            candidates = (frameworks / rel, root / rel, manifest.parent / rel)
            if not any(path.is_file() for path in candidates):
                raise SystemExit(f'Missing required native asset: {asset_id}: {rel}')
            print(f'verified native asset {asset_id}: {rel}')

# Validate embedded framework/dylib dependencies, including weak/re-exported
# dependencies and those of FFI frameworks that Runner does not link directly.
for path in iter_macho(app):
    for buf in slices(path):
        for cmd, blob in walk_cmds(buf):
            if cmd not in (0xC, 0x18, 0x80000018, 0x8000001F, 0x80000023):
                continue
            name = cmd_name(blob)
            if name.startswith('@rpath/'):
                rel = name[len('@rpath/'):]
                if not (frameworks / rel).is_file() and not rel.startswith('libswift'):
                    raise SystemExit(f'Missing embedded dependency: {path}: {name}')

# Do not claim compatibility below any embedded binary's deployment target.
minimum = (0, 0, 0)
for path in iter_macho(app):
    for buf in slices(path):
        for cmd, blob in walk_cmds(buf):
            if cmd == 0x32 and len(blob) >= 16:  # LC_BUILD_VERSION
                version = struct.unpack_from('<I', blob, 12)[0]
            elif cmd in (0x25, 0x2F) and len(blob) >= 12:
                version = struct.unpack_from('<I', blob, 8)[0]
            else:
                continue
            minimum = max(minimum, (version >> 16, (version >> 8) & 255, version & 255))
minimum_text = '.'.join(map(str, minimum[:2] if minimum[2] == 0 else minimum))
print(f'Embedded binaries require minimum iOS {minimum_text}')

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
            current = tuple(int(v) for v in str(pl.get("MinimumOSVersion", "0")).split("."))
            current = (current + (0, 0, 0))[:3]
            if current < minimum:
                pl["MinimumOSVersion"] = minimum_text
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

find "$APP/Frameworks" -mindepth 1 -maxdepth 1 -name '*.dylib' -print0 | while IFS= read -r -d '' lib; do
  codesign --force --sign - --timestamp=none "$lib"
done

sign_app "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

PAYLOAD="$(mktemp -d)"
trap 'rm -rf "$PAYLOAD"' EXIT

mkdir -p "$PAYLOAD/Payload"
cp -RP "$APP" "$PAYLOAD/Payload/"

OUT_ABS="$(cd "$(dirname "$OUT")" && pwd)/$(basename "$OUT")"
rm -f "$OUT_ABS"
(cd "$PAYLOAD" && zip -q -r -y "$OUT_ABS" Payload)

echo "Wrote $OUT_ABS"
