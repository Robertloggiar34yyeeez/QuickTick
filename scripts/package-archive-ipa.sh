#!/usr/bin/env bash
# Export exactly the Xcode-archived iPhone application. Rebuilding through a
# second toolchain can silently omit local Swift packages such as Mirage.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

APP="build/QuicktickNative.xcarchive/Products/Applications/QuicktickNative.app"
test -f "$APP/Info.plist"
test -f "$APP/QuicktickNative"

IPA_VERSION=$(python3 - <<'PY'
import pathlib, plistlib, re
root = pathlib.Path.cwd()
info = plistlib.loads((root/'build/QuicktickNative.xcarchive/Products/Applications/QuicktickNative.app/Info.plist').read_bytes())
version, build = info['CFBundleShortVersionString'], info['CFBundleVersion']
assert re.fullmatch(r'\d+\.\d+\.\d+', version), f'Unexpected app version: {version}'
assert build.isdigit() and int(build) > 0, f'Unexpected build number: {build}'
project = (root/'ios-starter/QuicktickNative.xcodeproj/project.pbxproj').read_text()
assert f'"MARKETING_VERSION" = "{version}";' in project, 'Archive version differs from Xcode project'
assert f'"CURRENT_PROJECT_VERSION" = "{build}";' in project, 'Archive build differs from Xcode project'
print(version)
PY
)

staging_dir=$(mktemp -d "${TMPDIR:-/tmp}/quicktick-ipa.XXXXXXXX")
trap 'rm -rf -- "$staging_dir"' EXIT
mkdir -p "$staging_dir/Payload" build/export
/usr/bin/ditto "$APP" "$staging_dir/Payload/QuicktickNative.app"
IPA_PATH="$ROOT/build/export/QuickTick-${IPA_VERSION}-unsigned.ipa"
(cd "$staging_dir" && /usr/bin/ditto -c -k --sequesterRsrc --keepParent Payload "$IPA_PATH")
shasum -a 256 "$IPA_PATH" > build/export/SHA256SUMS.txt
python3 scripts/verify-ipa.py "$IPA_PATH" build/export/SHA256SUMS.txt
cp ios-starter/Config/iPhone.entitlements build/export/iPhone.entitlements
printf '%s\n' \
    'Exported directly from the successfully archived Xcode iPhone app.' \
    'Includes the Mirage Metal runtime linked by Xcode.' \
    'Unsigned: install using AltStore/Sideloadly for signing.' \
    'Large on-device AI models need the bundled iPhone.entitlements when signing; some sideloaders may not preserve these permissions.' \
    "Git commit: ${GITHUB_SHA:-local}" \
    > build/export/INSTALLATION.txt
