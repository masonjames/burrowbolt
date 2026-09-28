#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build
export BURROWBOLT_VALIDATION_HEAD=$(git rev-parse HEAD)
export BURROWBOLT_VALIDATION_DIRTY=$(git status --porcelain)
rm -f build/validation.json
python3 scripts/check-capabilities.py
./build.sh
cargo test --locked --release --features cli
cargo build --locked --release --features cli --bin blitztree --bin bench
python3 tests/test_cli.py
python3 tests/test_mole_adapter.py
benchmarks/run-ui.sh --check-only
benchmarks/run-ui.sh --insights
benchmarks/run-agent.sh --check-only
python3 benchmarks/rendering.py --baseline "$(python3 -c 'import json; print(json.load(open("UPSTREAMS.lock"))["performance_baseline"])')" --check-only
python3 - <<'PY'
import datetime,json,os,pathlib,subprocess
head=subprocess.check_output(["git","rev-parse","HEAD"],text=True).strip()
dirty=subprocess.check_output(["git","status","--porcelain"],text=True).strip()
assert head==os.environ["BURROWBOLT_VALIDATION_HEAD"], "HEAD changed during validation; rerun on the final commit"
assert dirty==os.environ["BURROWBOLT_VALIDATION_DIRTY"], "Worktree changed during validation; rerun on the final source"
pathlib.Path('build/validation.json').write_text(json.dumps({
 'commit':head,
 'dirty':bool(dirty),
 'passed':True,'time':datetime.datetime.now(datetime.timezone.utc).isoformat(),
 'scope':'Local app build, worker/engine, CLI, adapter, rendering correctness. Performance, GUI, Mole full suites and signed-update acceptance are separate.'
},indent=2)+'\n')
PY
