#!/bin/zsh
# Deploy: rebuild and update the FDA-granted /Applications copy in place.
set -e; cd "$(dirname "$0")"; ./build.sh
# Clean replace: a ditto-merge over an old bundle can corrupt the signature,
# and an invalid signature makes TCC silently ignore the FDA grant.
rm -rf /Applications/BurrowBolt.app
ditto build/BurrowBolt.app /Applications/BurrowBolt.app
codesign --verify --strict /Applications/BurrowBolt.app
echo "==> Deployed to /Applications/BurrowBolt.app (signature verified)"
