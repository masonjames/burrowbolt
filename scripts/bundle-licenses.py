#!/usr/bin/env python3
import json, pathlib, shutil, subprocess, sys
out=pathlib.Path(sys.argv[1])
metadata=json.loads(subprocess.check_output(['cargo','metadata','--locked','--all-features','--format-version','1']))
for package in metadata['packages']:
    if package['source'] is None: continue
    root=pathlib.Path(package['manifest_path']).parent
    destination=out/(package['name']+'-'+package['version'])
    destination.mkdir(parents=True,exist_ok=True)
    files=[p for p in root.iterdir() if p.is_file() and p.name.upper().startswith(('LICENSE','COPYING','COPYRIGHT','NOTICE'))]
    if not files: raise SystemExit('Missing license text: '+package['name'])
    for file in files: shutil.copyfile(file,destination/file.name)
    (destination/'source.txt').write_text((package.get('repository') or package['source'])+'\n'+(package.get('license') or '')+'\n')
