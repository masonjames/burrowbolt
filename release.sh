#!/bin/zsh
# Produce an immutable, signed draft release. Publication is a separate acceptance gate.
set -euo pipefail
cd "$(dirname "$0")"
V=${1:?Usage: ./release.sh VERSION NOTES.md}
NOTES=${2:?Provide the reviewed release notes file}
[[ "$V" == "$(<VERSION)" ]] || { print -u2 'Version must match VERSION'; exit 1; }
[[ "$V" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]] || { print -u2 'Expected a numeric release version'; exit 1; }
TAG="burrowbolt-v$V" # Do not reuse inherited BlitzTree tags.
REPO=masonjames/burrowbolt
[[ -z "$(git status --porcelain)" ]] || { print -u2 'Release requires a clean checkout'; exit 1; }
HEAD_SHA=$(git rev-parse HEAD)
[[ "$(git rev-parse "$TAG^{commit}")" == "$HEAD_SHA" ]] || { print -u2 'Release tag must name HEAD'; exit 1; }
[[ -f build/validation.json ]] || { print -u2 'Run scripts/validate.sh on this commit first'; exit 1; }
python3 - "$HEAD_SHA" <<'PY'
import json,sys
v=json.load(open('build/validation.json'))
assert v['commit']==sys.argv[1] and v['passed'] and not v['dirty'], 'Validation receipt must match HEAD'
PY
: ${BURROWBOLT_SIGN_IDENTITY:?Set a Developer ID Application identity from Keychain}
: ${BURROWBOLT_NOTARY_PROFILE:?Set the notarytool Keychain profile name}
[[ "$BURROWBOLT_SIGN_IDENTITY" == 'Developer ID Application:'* ]] || exit 1
if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
    print -u2 'This release already exists; installers are immutable. Use a new version.'; exit 1
fi
# This read-only check fails before packaging when credentials are unavailable.
xcrun notarytool history --keychain-profile "$BURROWBOLT_NOTARY_PROFILE" >/dev/null
export BURROWBOLT_RELEASE=1
./build.sh
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
out="dist/$TAG"
[[ ! -e "$out" ]] || { print -u2 'Output version already exists; do not overwrite installers'; exit 1; }
mkdir -p "$out"
ditto -c -k --keepParent build/BurrowBolt.app "$stage/BurrowBolt.zip"
xcrun notarytool submit "$stage/BurrowBolt.zip" --keychain-profile "$BURROWBOLT_NOTARY_PROFILE" --wait
xcrun stapler staple build/BurrowBolt.app
xcrun stapler validate build/BurrowBolt.app
spctl --assess --type execute -v build/BurrowBolt.app
mkdir "$stage/dmg"
ditto build/BurrowBolt.app "$stage/dmg/BurrowBolt.app"
ln -s /Applications "$stage/dmg/Applications"
hdiutil create -volname BurrowBolt -srcfolder "$stage/dmg" -format UDZO -quiet "$out/BurrowBolt.dmg"
codesign --timestamp --sign "$BURROWBOLT_SIGN_IDENTITY" "$out/BurrowBolt.dmg"
xcrun notarytool submit "$out/BurrowBolt.dmg" --keychain-profile "$BURROWBOLT_NOTARY_PROFILE" --wait
xcrun stapler staple "$out/BurrowBolt.dmg"
xcrun stapler validate "$out/BurrowBolt.dmg"
spctl --assess --type open --context context:primary-signature -v "$out/BurrowBolt.dmg"
# Corresponding source includes the pristine subtree, integration patches and locked Rust sources.
mkdir -p "$stage/source/.cargo"
git archive HEAD | tar -x -C "$stage/source"
cargo vendor --locked "$stage/source/vendor/rust" > "$stage/source/.cargo/config.toml"
# Cargo prints an absolute destination; make the published source archive relocatable.
python3 - "$stage/source/.cargo/config.toml" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]);s=p.read_text();s='\n'.join('directory = "vendor/rust"' if l.startswith('directory = ') else l for l in s.splitlines())+'\n';p.write_text(s)
PY
python3 scripts/bundle-sparkle-source.py "$stage/source/vendor/sparkle"
tar -czf "$stage/BurrowBolt-source.tar.gz" -C "$stage/source" .
cp "$NOTES" "$out/BurrowBolt.md"
SPARKLE=$(python3 scripts/fetch-sparkle.py)
"$SPARKLE/bin/generate_appcast" --account burrowbolt --maximum-deltas 0 --embed-release-notes \
    --download-url-prefix "https://github.com/$REPO/releases/download/$TAG/" "$out"
"$SPARKLE/bin/sign_update" --account burrowbolt --verify "$out/appcast.xml"
mv "$stage/BurrowBolt-source.tar.gz" "$out/BurrowBolt-source.tar.gz"
python3 scripts/check-appcast.py "$out/appcast.xml" "$TAG"
(cd "$out" && shasum -a 256 BurrowBolt.dmg BurrowBolt-source.tar.gz > SHA256SUMS.txt)
gh release create "$TAG" "$out/BurrowBolt.dmg" "$out/BurrowBolt-source.tar.gz" "$out/SHA256SUMS.txt" \
    "$out/appcast.xml" --repo "$REPO" --verify-tag --draft --title "BurrowBolt $V" --notes-file "$NOTES"
print "Draft ready. Validate installation and an older-to-newer update before publishing $TAG and its signed appcast."
