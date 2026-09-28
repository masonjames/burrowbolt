#!/usr/bin/env python3
"""Pinned test-only runner; never bundled or required at runtime."""
import hashlib,json,pathlib,subprocess,urllib.request
root=pathlib.Path(__file__).resolve().parents[1]
pin=json.loads((root/'UPSTREAMS.lock').read_text())['bats']
folder=root/'build/tools'; folder.mkdir(parents=True,exist_ok=True)
archive=folder/'bats.tar.gz'
if not archive.exists():
    with urllib.request.urlopen(pin['url'],timeout=60) as response: data=response.read()
    assert hashlib.sha256(data).hexdigest()==pin['sha256'], 'Bats download checksum mismatch'
    archive.write_bytes(data)
assert hashlib.sha256(archive.read_bytes()).hexdigest()==pin['sha256'], 'Bats checksum mismatch'
destination=folder/'bats';destination.mkdir(exist_ok=True)
subprocess.run(['tar','-xf',str(archive),'--strip-components=1','-C',str(destination)],check=True)
