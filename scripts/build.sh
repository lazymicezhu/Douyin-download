#!/bin/zsh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
mkdir -p build dist
python3 scripts/generate_project.py
# Xcode dependency files cannot reliably handle ':' in an iCloud workspace path.
# Stage only source/project files in a simple temporary path; never copy .env.
STAGE="$(mktemp -d /private/tmp/douyin-lite.XXXXXX)"
trap 'rm -rf "$STAGE"' EXIT
ditto "$ROOT/DouyinLite" "$STAGE/DouyinLite"
ditto "$ROOT/DouyinLite.xcodeproj" "$STAGE/DouyinLite.xcodeproj"
SDK=iphoneos
DESTINATION='generic/platform=iOS'
if [[ "${1:-}" == '--simulator' ]]; then
  SDK=iphonesimulator
  DESTINATION='generic/platform=iOS Simulator'
fi
xcodebuild -quiet -jobs 1 -project "$STAGE/DouyinLite.xcodeproj" -scheme DouyinLite \
  -configuration Release -sdk "$SDK" -destination "$DESTINATION" \
  -derivedDataPath "$STAGE/build" \
  CLANG_MODULE_CACHE_PATH="$STAGE/build/ModuleCache.noindex" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY='' build
if [[ "$SDK" == iphonesimulator ]]; then
  ditto "$STAGE/build/Build/Products/Release-iphonesimulator/DouyinLite.app" "$ROOT/build/Simulator/DouyinLite.app"
  print 'Built build/Simulator/DouyinLite.app'
  exit 0
fi
PACKAGE="$STAGE/package"
mkdir -p "$PACKAGE/Payload"
ditto "$STAGE/build/Build/Products/Release-iphoneos/DouyinLite.app" "$PACKAGE/Payload/DouyinLite.app"
rm -f "$ROOT/dist/DouyinLite-unsigned.ipa"
(cd "$PACKAGE" && /usr/bin/zip -qr "$ROOT/dist/DouyinLite-unsigned.ipa" Payload)
python3 - <<'PY'
import os
from pathlib import Path
source = Path('.env')
has_configuration = source.exists()
if has_configuration:
    for name in ['TikHub.env', 'TikHub.txt']:
        destination = Path('dist') / name
        destination.write_bytes(source.read_bytes())
        os.chmod(destination, 0o600)
print('Built dist/DouyinLite-unsigned.ipa (import into 全能签 to sign and install).')
if has_configuration:
    print('Import dist/TikHub.txt once in the app settings; it contains your private API key.')
else:
    print('No .env configuration was copied. Set your API key in the app settings.')
PY
