#!/bin/bash
# Only patch an expendable build copy. The subtree itself stays pristine.
set -euo pipefail
cd "$(dirname "$0")/.."
stage=build/mole
mkdir -p build
rm -rf "$stage"
mkdir -p "$stage"
cp -R vendor/mole/bin vendor/mole/lib vendor/mole/LICENSE "$stage/"
for patch_file in integration/mole/state.patch integration/mole/readonly.patch; do
    /usr/bin/patch --batch --forward --fuzz=0 -d "$stage" -p1 < "$patch_file"
done
