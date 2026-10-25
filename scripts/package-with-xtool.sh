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
IPA_VERSION=$(python3 - <<'PY'
import pathlib, plistlib, re
root = pathlib.Path.cwd()
app = root/'build/QuicktickNative.xcarchive/Products/Applications/QuicktickNative.app'
info = plistlib.loads((app/'Info.plist').read_bytes())
version = info['CFBundleShortVersionString']
build = info['CFBundleVersion']
assert re.fullmatch(r'\d+\.\d+\.\d+', version), f'Unexpected app version: {version}'
assert build.isdigit() and int(build) > 0, f'Unexpected build number: {build}'
project = (root/'ios-starter/QuicktickNative.xcodeproj/project.pbxproj').read_text()
assert f'"MARKETING_VERSION" = "{version}";' in project, 'IPA version differs from Xcode project'
assert f'"CURRENT_PROJECT_VERSION" = "{build}";' in project, 'IPA build differs from Xcode project'
(root/'ios-starter/Config/xtool-Info.plist').write_bytes(plistlib.dumps(info))
print(version)
PY
)
cd ios-starter
# No --sign: the user requested an unsigned IPA for AltStore/Sideloadly.
"$XTOOL_BIN" dev build --configuration release --ipa 2>&1 | tee ../logs/xtool-app-package.txt
cd "$ROOT"
mkdir -p build/export
IPA_PATH="build/export/QuickTick-${IPA_VERSION}-unsigned.ipa"
cp ios-starter/xtool/QuicktickNative.ipa "$IPA_PATH"
shasum -a 256 "$IPA_PATH" > build/export/SHA256SUMS.txt
python3 scripts/verify-ipa.py "$IPA_PATH" build/export/SHA256SUMS.txt
printf '%s\n' 'Native direct-provider build; packaged by xtool from the verified user-supplied source.' 'Unsigned: install using AltStore/Sideloadly.' "Git commit: $GITHUB_SHA" > build/export/INSTALLATION.txt
