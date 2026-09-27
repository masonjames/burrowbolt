#!/bin/bash
# Test the patched build copy while leaving vendor/mole pristine.
set -euo pipefail
cd "$(dirname "$0")/.."
[[ -x build/tools/bats/bin/bats ]] || { echo 'Install Bats in PATH or fetch the pinned test runner into build/tools/bats.' >&2; exit 1; }
stage=build/mole-tests
rm -rf "$stage"
mkdir -p "$stage"
cp -R vendor/mole/. "$stage/"
patch --batch --forward --fuzz=0 -d "$stage" -p1 < integration/mole/state.patch
patch --batch --forward --fuzz=0 -d "$stage" -p1 < integration/mole/readonly.patch
patch --batch --forward --fuzz=0 -d "$stage" -p1 < integration/mole/test-fixture.patch
# The same assertions exercise the deliberately namespaced contract.
python3 - "$stage/tests" <<'PY'
from pathlib import Path
import sys
for p in Path(sys.argv[1]).rglob('*'):
    if p.suffix not in ('.bats','.bash','.sh'): continue
    s=p.read_text().replace('${XDG_CACHE_HOME:-$HOME/.cache}/mole','$HOME/Library/Caches/com.masonjames.burrowbolt/mole').replace('Library/Logs/mole','Library/Logs/BurrowBolt').replace('.config/mole','Library/Application Support/BurrowBolt/mole').replace('.cache/mole','Library/Caches/com.masonjames.burrowbolt/mole')
    p.write_text(s)
PY
MOLE_TEST_NO_AUTH=1 build/tools/bats/bin/bats "$stage/tests/purge.bats" "$stage/tests/installer.bats" \
    "$stage/tests/installer_zip.bats" "$stage/tests/clean_core.bats" "$stage/tests/file_ops_mole_delete.bats" \
    "$stage/tests/clean_apps.bats" "$stage/tests/clean_app_caches.bats" "$stage/tests/clean_dev_caches.bats"
