#!/usr/bin/env python3
"""Fetch the exact framework archive in UPSTREAMS.lock and verify before extraction."""
import hashlib, json, pathlib, subprocess, urllib.request
root = pathlib.Path(__file__).resolve().parents[1]
pin = json.loads((root / "UPSTREAMS.lock").read_text())["sparkle"]
cache = root / "build" / ("Sparkle-" + pin["version"])
archive = root / "build" / ("Sparkle-" + pin["version"] + ".tar.xz")
archive.parent.mkdir(exist_ok=True)
if not archive.exists():
    with urllib.request.urlopen(pin["url"], timeout=60) as response:
        data = response.read()
    if hashlib.sha256(data).hexdigest() != pin["sha256"]:
        raise SystemExit("Sparkle checksum mismatch; archive was not extracted")
    archive.write_bytes(data)
if hashlib.sha256(archive.read_bytes()).hexdigest() != pin["sha256"]:
    raise SystemExit("Cached Sparkle checksum mismatch; remove the archive and retry")
if not (cache / "Sparkle.framework").is_dir():
    cache.mkdir(exist_ok=True)
    subprocess.run(["tar", "-xf", str(archive), "-C", str(cache)], check=True)
print(cache)
