#!/bin/zsh
# Production Swift sources with synthetic fixtures or a real read-only scan.
set -euo pipefail
cd "$(dirname "$0")/.."
UI_BENCH_TMP=$(mktemp -d /tmp/blitztree-ui-bench.XXXXXX)
trap 'rm -rf "$UI_BENCH_TMP"' EXIT
# Freeze the source set while other audit work may still edit shared files.
mkdir "$UI_BENCH_TMP/app"
cp app/*.swift "$UI_BENCH_TMP/app/"
shasum -a 256 "$UI_BENCH_TMP/app/Cleanup.swift" "$UI_BENCH_TMP/app/Model.swift" "$UI_BENCH_TMP/app/ContentView.swift"
UI_BENCH_INPUTS=(benchmarks/UIPerformance.swift)
SPARKLE=$(python3 scripts/fetch-sparkle.py)
SENTRY=$(python3 scripts/fetch-sentry.py)
UI_BENCH_LINK=(-F "$SENTRY" -framework Sentry -Xlinker -rpath -Xlinker "$SENTRY" -F "$SPARKLE" -framework Sparkle -Xlinker -rpath -Xlinker "$SPARKLE")
UI_BENCH_HEADER=benchmarks/ui_fixture.h
if [[ "${1:-}" == --worker ]]; then
  shift
  UI_BENCH_INPUTS=(benchmarks/WorkerCheck.swift)
  clang -O2 -mmacosx-version-min=14.0 -c benchmarks/ui_fixture.c -o "$UI_BENCH_TMP/fixture.o"
  UI_BENCH_INPUTS+=("$UI_BENCH_TMP/fixture.o")
elif [[ "${1:-}" == --insights ]]; then
  shift
  UI_BENCH_INPUTS=(benchmarks/InsightsCheck.swift)
  UI_BENCH_LINK+=(-L target/release -lblitztree)
  UI_BENCH_HEADER=app/bz.h
elif [[ "${1:-}" == --scan-path ]]; then
  shift
  [[ $# -ge 1 ]] || { print -u2 'Usage: run-ui.sh --scan-path PATH [PATH ...]'; exit 2; }
  [[ -f target/release/libblitztree.a ]] || { print -u2 'Build the Rust library first: cargo build --release'; exit 2; }
  UI_BENCH_INPUTS=(benchmarks/UICleanupScan.swift)
  UI_BENCH_LINK+=(-L target/release -lblitztree)
  UI_BENCH_HEADER=app/bz.h
else
  clang -O2 -mmacosx-version-min=14.0 -c benchmarks/ui_fixture.c -o "$UI_BENCH_TMP/fixture.o"
  UI_BENCH_INPUTS+=("$UI_BENCH_TMP/fixture.o")
fi
swiftc "$UI_BENCH_TMP/app/Diagnostics.swift" "$UI_BENCH_TMP/app/Worker.swift" "$UI_BENCH_TMP/app/Insights.swift" "$UI_BENCH_TMP/app/Updater.swift" "$UI_BENCH_TMP/app/Agent.swift" "$UI_BENCH_TMP/app/Cleanup.swift" \
  "$UI_BENCH_TMP/app/ContentView.swift" "$UI_BENCH_TMP/app/Model.swift" \
  "$UI_BENCH_TMP/app/Treemap.swift" "$UI_BENCH_TMP/app/TreemapView.swift" "$UI_BENCH_TMP/app/SunburstView.swift" \
  "${UI_BENCH_INPUTS[@]}" benchmarks/UIReferenceCleanup.swift "${UI_BENCH_LINK[@]}" \
  -import-objc-header "$UI_BENCH_HEADER" \
  -O -parse-as-library -swift-version 6 -default-isolation MainActor \
  -target arm64-apple-macos14.0 -framework AppKit -framework SwiftUI \
  -o "$UI_BENCH_TMP/ui-bench"
"$UI_BENCH_TMP/ui-bench" "$@"
