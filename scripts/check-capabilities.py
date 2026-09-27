#!/usr/bin/env python3
"""Fail when pinned upstream names or integration patch assumptions drift."""
import json, pathlib, re, subprocess
root=pathlib.Path(__file__).resolve().parents[1]
lock=json.loads((root/'UPSTREAMS.lock').read_text())
assert lock['mole']['subtree']=='vendor/mole'
source=(root/'vendor/mole/lib/clean/purge_shared.sh').read_text()
block=source.split('readonly MOLE_PURGE_TARGETS=(',1)[1].split('\n)',1)[0]
expected=set(re.findall(r'^\s*"([^"\n]+)"',block,re.M))
app=(root/'app/Insights.swift').read_text().split('static let projectNames:',1)[1].split(']',1)[0]
actual=set(re.findall(r'"([^"\n]+)"',app))
assert expected==actual, f'Project rule drift: missing={expected-actual}, added={actual-expected}'
modules='\n'.join(p.read_text() for p in (root/'vendor/mole').glob('lib/clean/*.sh'))+'\n'+(root/'vendor/mole/bin/clean.sh').read_text()
for name in (root/'integration/mole/families.txt').read_text().splitlines():
    assert re.search(r'^'+re.escape(name)+r'\(\)',modules,re.M), f'Missing family {name}'
subprocess.run(['git','diff','HEAD','--exit-code','--','vendor/mole'],cwd=root,check=True)
actual_tree=subprocess.check_output(['git','rev-parse','HEAD:vendor/mole'],cwd=root,text=True).strip()
assert actual_tree==lock['mole']['tree'], 'Vendored tree does not match the pinned pristine import' 
print('PASS: pristine subtree, 34 project targets, and all declared Mole families present')
