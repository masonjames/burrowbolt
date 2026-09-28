#!/usr/bin/env python3
"""Exercise real clean/conflicting Git merges; GitHub calls use a fixture executable."""
import json,os,pathlib,subprocess,tempfile
SCRIPT=pathlib.Path(__file__).resolve().parents[1]/'scripts/update-upstream.py'
with tempfile.TemporaryDirectory(prefix='burrowbolt-upstream-') as temp:
    base=pathlib.Path(temp);bin=base/'bin';bin.mkdir()
    gh=bin/'gh';gh.write_text('#!/bin/sh\nif [ "$1 $2" = "pr list" ]; then echo "[]"; else printf "%s\\n" "$*" >> "$BB_TEST_LOG"; fi\n');gh.chmod(0o700)
    env={**os.environ,'PATH':str(bin)+':'+os.environ['PATH'],'GIT_CONFIG_COUNT':'1','GIT_CONFIG_KEY_0':'commit.gpgsign','GIT_CONFIG_VALUE_0':'false',
         'GIT_AUTHOR_NAME':'Fixture','GIT_AUTHOR_EMAIL':'fixture@example.invalid','GIT_COMMITTER_NAME':'Fixture','GIT_COMMITTER_EMAIL':'fixture@example.invalid','BB_TEST_LOG':str(base/'github-calls')}
    def git(cwd,*args):return subprocess.check_output(['git',*args],cwd=cwd,env=env,stderr=subprocess.DEVNULL,text=True).strip()
    for conflict in (False,True):
        case=base/str(conflict);case.mkdir();upstream=case/'upstream';upstream.mkdir()
        git(upstream,'init','-b','main');(upstream/'file').write_text('base\n');git(upstream,'add','.');git(upstream,'commit','-m','base');original=git(upstream,'rev-parse','HEAD')
        fork=case/'fork';git(case,'clone',str(upstream),str(fork))
        origin=case/'origin.git';git(case,'init','--bare',str(origin));git(fork,'remote','set-url','origin',str(origin))
        lock={'blitztree':{'repository':str(upstream),'commit':original}}
        (fork/'UPSTREAMS.lock').write_text(json.dumps(lock));(fork/'file').write_text('fork\n');git(fork,'add','.');git(fork,'commit','-m','fork');git(fork,'push','origin','main')
        (upstream/('file' if conflict else 'new-file')).write_text('upstream\n');git(upstream,'add','.');git(upstream,'commit','-m','update');target=git(upstream,'rev-parse','HEAD')
        subprocess.run(['python3',str(SCRIPT),'blitztree'],cwd=fork,env=env,check=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        current=json.loads((fork/'UPSTREAMS.lock').read_text())['blitztree']['commit']
        assert current==(original if conflict else target)
        if conflict:
            report=(fork/'docs/UPSTREAM_REVIEW.md').read_text();assert target in report and '`file`' in report and 'not imported' in report
            assert (fork/'file').read_text()=='fork\n'
        else:assert (fork/'new-file').read_text()=='upstream\n'
        assert not git(fork,'status','--porcelain')
    calls=(base/'github-calls').read_text();assert calls.count('pr create --draft')==2 and calls.count('workflow run ci.yml')==2
print('PASS: clean update imported; conflicting update opens a blocked review without changing the pin; both dispatch validation')
