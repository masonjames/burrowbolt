#!/usr/bin/env python3
"""Fetch the pinned Cocoa SDK; extract only its macOS framework."""
import hashlib, json, pathlib, subprocess, urllib.request
root = pathlib.Path(__file__).resolve().parents[1]
pin = json.loads((root / "UPSTREAMS.lock").read_text())["sentry"]
cache = root / "build" / ("Sentry-" + pin["version"])
archive = cache.parent / (cache.name + ".zip")
archive.parent.mkdir(exist_ok=True)
if not archive.exists():
    with urllib.request.urlopen(pin["url"], timeout=60) as response:
        data = response.read()
    if hashlib.sha256(data).hexdigest() != pin["sha256"]:
        raise SystemExit("Sentry checksum mismatch")
    archive.write_bytes(data)
if hashlib.sha256(archive.read_bytes()).hexdigest() != pin["sha256"]:
    raise SystemExit("Cached Sentry checksum mismatch")
framework = cache / "Sentry-Dynamic.xcframework/macos-arm64_x86_64"
if not (framework / "Sentry.framework/Sentry").exists():
    subprocess.run(["unzip", "-q", "-o", str(archive),
                    "Sentry-Dynamic.xcframework/macos-arm64_x86_64/*", "-d", str(cache)], check=True)
print(framework)
