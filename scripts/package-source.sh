#!/bin/zsh
# Corresponding source for the exact clean revision used by either installer.
set -euo pipefail
cd "$(dirname "$0")/.."
out=${1:?Usage: scripts/package-source.sh OUTPUT.tar.gz}
[[ -z "$(git status --porcelain)" ]] || { print -u2 'Source packaging requires a clean checkout'; exit 1; }
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
mkdir -p "$stage/source/.cargo"
git archive HEAD | tar -x -C "$stage/source"
cargo vendor --locked "$stage/source/vendor/rust" > "$stage/source/.cargo/config.toml"
python3 - "$stage/source/.cargo/config.toml" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1])
p.write_text('\n'.join('directory = "vendor/rust"' if line.startswith('directory = ') else line for line in p.read_text().splitlines())+'\n')
PY
python3 scripts/bundle-framework-source.py "$stage/source/vendor/sparkle"
python3 scripts/bundle-framework-source.py "$stage/source/vendor/sentry-cocoa" sentry
tar -czf "$out" -C "$stage/source" .
