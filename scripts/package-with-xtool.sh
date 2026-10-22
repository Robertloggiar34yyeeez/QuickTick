#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
python3 scripts/prepare-xtool.py
xcrun simctl shutdown all || true
export XTOOL_VERSION="drive-archive-d802c719e43fb2d66a7c7879f7dff75bfdd96a27"
swift build --package-path tools/xtool-source --configuration release --jobs 2 --product xtool 2>&1 | tee logs/xtool-tool-build.txt
XTOOL_BIN_DIR=$(swift build --package-path tools/xtool-source --configuration release --show-bin-path)
XTOOL_BIN="$XTOOL_BIN_DIR/xtool"
"$XTOOL_BIN" --help > logs/xtool-help.txt
python3 - <<'PY'
import pathlib, plistlib
root = pathlib.Path.cwd()
app = root/'build/QuicktickNative.xcarchive/Products/Applications/QuicktickNative.app'
info = plistlib.loads((app/'Info.plist').read_bytes())
assert info['CFBundleVersion'] == '26' and info['CFBundleShortVersionString'] == '0.9.6'
(root/'ios-starter/Config/xtool-Info.plist').write_bytes(plistlib.dumps(info))
PY
cd ios-starter
# No --sign: the user requested an unsigned IPA for AltStore/Sideloadly.
"$XTOOL_BIN" dev build --configuration release --ipa 2>&1 | tee ../logs/xtool-app-package.txt
cd "$ROOT"
mkdir -p build/export
cp ios-starter/xtool/QuicktickNative.ipa build/export/QuickTick-0.9.6-unsigned.ipa
shasum -a 256 build/export/QuickTick-0.9.6-unsigned.ipa > build/export/SHA256SUMS.txt
python3 scripts/verify-ipa.py build/export/QuickTick-0.9.6-unsigned.ipa build/export/SHA256SUMS.txt
printf '%s\n' 'Native direct-provider build; packaged by xtool from the verified user-supplied source.' 'Unsigned: install using AltStore/Sideloadly.' "Git commit: $GITHUB_SHA" > build/export/INSTALLATION.txt
