#!/usr/bin/env python3
"""One reviewable PR per upstream revision. Never auto-merge cleanup changes."""
import json, pathlib, subprocess, sys, tempfile
name = sys.argv[1]
assert name in ('blitztree', 'mole')
lockfile = pathlib.Path('UPSTREAMS.lock')
lock = json.loads(lockfile.read_text())
pin = lock[name]
def run(*args, capture=False):
    return subprocess.check_output(args, text=True).strip() if capture else subprocess.run(args, check=True)
run('git','config','user.name','BurrowBolt upstream review')
run('git','config','user.email','upstreams@users.noreply.github.com')
run('git','fetch',pin['repository'],'main')
sha = run('git','rev-parse','FETCH_HEAD',capture=True)
if sha == pin['commit']:
    raise SystemExit(0)
branch = f'codex/upstream-{name}-{sha[:12]}'
if run('gh','pr','list','--head',branch,'--state','all','--json','number',capture=True) != '[]':
    raise SystemExit(0)
run('git','checkout','-b',branch)
if name == 'mole':
    run('git','subtree','pull','--prefix','vendor/mole',pin['repository'],sha,'--squash')
else:
    # Conflicts fail the run for human resolution instead of selecting a side.
    run('git','merge','--no-edit',sha)
lock[name]['commit'] = sha
if name == 'mole': lock[name]['tree'] = run('git','rev-parse',sha+'^{tree}',capture=True)
lockfile.write_text(json.dumps(lock,indent=2)+'\n')
run('git','add','UPSTREAMS.lock')
run('git','commit','-m',f'Record reviewed {name} update candidate {sha[:12]}')
run('git','push','origin',branch)
with tempfile.NamedTemporaryFile(mode='w',suffix='.md') as body:
    body.write(f'Imports {name} at `{sha}`.\n\nRequire the app/worker tests, applicable Mole safeguards, capability-matrix review and paired performance results before merging. New destructive rules require explicit coverage review. Automatic AI planning remains a BurrowBolt product requirement.\n')
    body.flush()
    run('gh','pr','create','--draft','--head',branch,'--title',f'Review {name} upstream {sha[:12]}','--body-file',body.name)

# GITHUB_TOKEN-created PRs do not trigger pull_request checks; dispatch them explicitly.
run('gh','workflow','run','ci.yml','--ref',branch)
