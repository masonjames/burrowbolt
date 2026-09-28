#!/bin/zsh
# Local, explicitly unnotarized installer for development verification only.
set -euo pipefail
cd "$(dirname "$0")/.."
./build.sh
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
mkdir -p dist/development
ditto build/BurrowBolt.app "$stage/BurrowBolt.app"
ln -s /Applications "$stage/Applications"
hdiutil create -volname 'BurrowBolt Development' -srcfolder "$stage" -ov -format UDZO -quiet dist/development/BurrowBolt.dmg
if [[ -n ${BURROWBOLT_SIGN_IDENTITY:-} && "$BURROWBOLT_SIGN_IDENTITY" != - ]]; then
    codesign --timestamp --sign "$BURROWBOLT_SIGN_IDENTITY" dist/development/BurrowBolt.dmg
    codesign --verify --strict dist/development/BurrowBolt.dmg
fi
shasum -a 256 dist/development/BurrowBolt.dmg > dist/development/SHA256SUMS.txt
print 'Development DMG: dist/development/BurrowBolt.dmg (not notarized; not a public release)'
