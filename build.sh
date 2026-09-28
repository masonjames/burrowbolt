#!/bin/zsh
# Native Apple Silicon application; build tools are never runtime dependencies.
set -euo pipefail
cd "$(dirname "$0")"
[[ -f "$HOME/.cargo/env" ]] && source "$HOME/.cargo/env"
VERSION=$(<VERSION)
export BURROWBOLT_SPARKLE_PUBLIC_KEY=${BURROWBOLT_SPARKLE_PUBLIC_KEY:-$(<config/Sparkle.pub)}
MIN_MACOS=14.0
export MACOSX_DEPLOYMENT_TARGET=$MIN_MACOS
SPARKLE=$(python3 scripts/fetch-sparkle.py)
IDENTITY=${BURROWBOLT_SIGN_IDENTITY:--}
if [[ ${BURROWBOLT_RELEASE:-0} == 1 ]]; then
    [[ "$IDENTITY" == 'Developer ID Application:'* ]] || { print -u2 'Release requires BURROWBOLT_SIGN_IDENTITY (Developer ID Application).'; exit 1; }
    [[ -n ${BURROWBOLT_SPARKLE_PUBLIC_KEY:-} ]] || { print -u2 'Release requires the Sparkle public key.'; exit 1; }
fi
cargo build --locked --release --features cli --bin burrowbolt-worker --lib
scripts/prepare-mole.sh
APP=build/BurrowBolt.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/Licenses" "$APP/Contents/Frameworks"
ditto "$SPARKLE/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
ditto build/mole "$APP/Contents/Resources/mole"
cp LICENSE NOTICE LICENSES/* "$APP/Contents/Resources/Licenses/"
python3 scripts/bundle-licenses.py "$APP/Contents/Resources/Licenses"
cp "$SPARKLE/LICENSE" "$APP/Contents/Resources/Licenses/Sparkle.txt"
cp target/release/burrowbolt-worker "$APP/Contents/MacOS/"
cp integration/mole/families.txt "$APP/Contents/Resources/"
cp integration/mole/adapter.sh "$APP/Contents/Resources/"
cp UPSTREAMS.lock "$APP/Contents/Resources/"
swiftc app/*.swift -import-objc-header app/bz.h \
    -O -g -parse-as-library -swift-version 6 -default-isolation MainActor \
    -target arm64-apple-macos$MIN_MACOS -L target/release -lblitztree \
    -F "$SPARKLE" -framework Sparkle -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
    -framework AppKit -framework SwiftUI -o "$APP/Contents/MacOS/BurrowBolt"
export BURROWBOLT_SOURCE_COMMIT=$(git rev-parse HEAD)
python3 - "$APP" "$VERSION" <<'PY'
import os, pathlib, plistlib, sys
app, version = pathlib.Path(sys.argv[1]), sys.argv[2]
info = dict(CFBundleName='BurrowBolt', CFBundleDisplayName='BurrowBolt',
    CFBundleIdentifier='com.masonjames.burrowbolt', CFBundleVersion=version,
    CFBundleShortVersionString=version, CFBundleExecutable='BurrowBolt',
    CFBundlePackageType='APPL', LSMinimumSystemVersion='14.0',
    LSApplicationCategoryType='public.app-category.utilities',
    CFBundleIconFile='AppIcon', CFBundleIconName='AppIcon', NSHighResolutionCapable=True,
    NSHumanReadableCopyright='BurrowBolt contributors; BlitzTree and Mole contributors. GPLv3.',
    SUFeedURL='https://masonjames.github.io/burrowbolt/appcast.xml',
    SUAutomaticallyUpdate=False, SUAllowsAutomaticUpdates=False, SUEnableSystemProfiling=False,
    BurrowBoltSourceCommit=os.environ["BURROWBOLT_SOURCE_COMMIT"],
    SURequireSignedFeed=True, SUVerifyUpdateBeforeExtraction=True,
    BurrowBoltDevelopmentBuild=os.environ.get('BURROWBOLT_RELEASE') != '1')
key = os.environ.get('BURROWBOLT_SPARKLE_PUBLIC_KEY')
if key:
    info['SUPublicEDKey'] = key
(app / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
PY
print -n 'APPL????' > "$APP/Contents/PkgInfo"
xcrun actool "$PWD/assets/AppIcon.icon" --compile "$PWD/$APP/Contents/Resources" \
    --platform macosx --target-device mac --minimum-deployment-target $MIN_MACOS \
    --app-icon AppIcon --output-partial-info-plist "$PWD/build/icon-partial.plist" >/dev/null
# Retain matching symbols outside the app: local crash reports and future Sentry
# reports need these exact UUIDs. Debug sections do not ship in the installer.
rm -rf build/symbols
mkdir -p build/symbols
# swiftc already runs dsymutil before deleting its temporary object files.
mv "$APP/Contents/MacOS/BurrowBolt.dSYM" build/symbols/
xcrun dsymutil "$APP/Contents/MacOS/burrowbolt-worker" -o build/symbols/burrowbolt-worker.dSYM
for binary in BurrowBolt burrowbolt-worker; do
    strip -S "$APP/Contents/MacOS/$binary"
done
SIGN_ARGS=(--force --sign "$IDENTITY")
if [[ "$IDENTITY" != - ]]; then SIGN_ARGS+=(--options runtime --timestamp); fi
FRAMEWORK="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
for nested in "$FRAMEWORK/XPCServices/Installer.xpc" "$FRAMEWORK/XPCServices/Downloader.xpc" \
    "$FRAMEWORK/Autoupdate" "$FRAMEWORK/Updater.app" "$APP/Contents/Frameworks/Sparkle.framework"; do
    codesign "${SIGN_ARGS[@]}" "$nested"
done
codesign "${SIGN_ARGS[@]}" "$APP/Contents/MacOS/burrowbolt-worker"
codesign "${SIGN_ARGS[@]}" "$APP"
codesign --verify --deep --strict "$APP"
print "Built $APP"
