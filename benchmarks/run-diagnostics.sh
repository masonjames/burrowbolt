#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
SENTRY=$(python3 scripts/fetch-sentry.py)
APP=build/DiagnosticsCheck.app
mkdir -p "$APP/Contents/MacOS"
python3 - <<'PY'
import pathlib,plistlib
info=plistlib.load(open('build/BurrowBolt.app/Contents/Info.plist','rb'))
info.update(CFBundleIdentifier='com.masonjames.burrowbolt.diagnostics-check',CFBundleExecutable='DiagnosticsCheck',CFBundleName='DiagnosticsCheck')
pathlib.Path('build/DiagnosticsCheck.app/Contents/Info.plist').write_bytes(plistlib.dumps(info))
PY
swiftc app/Diagnostics.swift benchmarks/DiagnosticsCheck.swift -O -g -parse-as-library \
    -swift-version 6 -default-isolation MainActor -target arm64-apple-macos14.0 \
    -F "$SENTRY" -framework Sentry -Xlinker -rpath -Xlinker "$SENTRY" \
    -framework AppKit -framework SwiftUI -o "$APP/Contents/MacOS/DiagnosticsCheck"
"$APP/Contents/MacOS/DiagnosticsCheck" "${1:-check}"
