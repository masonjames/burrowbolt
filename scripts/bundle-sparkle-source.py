#!/usr/bin/env python3
"""Include the pinned framework source with corresponding-source releases."""
import hashlib,json,pathlib,subprocess,sys,urllib.request
root=pathlib.Path(__file__).resolve().parents[1]
pin=json.loads((root/'UPSTREAMS.lock').read_text())['sparkle']['source']
archive=root/'build/Sparkle-source.tar.gz'
if not archive.exists():
    with urllib.request.urlopen(pin['url'],timeout=60) as response:data=response.read()
    assert hashlib.sha256(data).hexdigest()==pin['sha256'],'Sparkle source checksum mismatch'
    archive.write_bytes(data)
assert hashlib.sha256(archive.read_bytes()).hexdigest()==pin['sha256'],'Sparkle source checksum mismatch'
out=pathlib.Path(sys.argv[1]);out.mkdir(parents=True,exist_ok=True)
subprocess.run(['tar','-xf',str(archive),'--strip-components=1','-C',str(out)],check=True)
