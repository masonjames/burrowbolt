#!/usr/bin/env python3
"""Read-only enrichment/navigation profile; samples RSS of the app and its descendants."""
import json,os,pathlib,plistlib,shutil,subprocess,time
root=pathlib.Path(__file__).resolve().parents[1]
app=root/'build/Enrichment.app'
if app.exists():shutil.rmtree(app)
shutil.copytree(root/'build/BurrowBolt.app',app,symlinks=True)
exe=app/'Contents/MacOS/BurrowBolt'
shutil.copyfile(root/'build/first-map/candidate/first-map',exe)
info=app/'Contents/Info.plist';p=plistlib.loads(info.read_bytes());p['CFBundleIdentifier']='com.masonjames.burrowbolt.benchmark';info.write_bytes(plistlib.dumps(p))
subprocess.run(['codesign','--force','--sign','-',str(app)],check=True)
out=root/'build/enrichment-profile.txt'
with out.open('w') as log:
    process=subprocess.Popen([str(exe),os.path.expanduser('~'),'--enrich'],stdout=log,stderr=log,env={**os.environ,'BURROWBOLT_QA_NO_AGENT':'1'})
    samples=[];started=time.monotonic()
    while process.poll() is None:
        text=subprocess.check_output(['/bin/ps','-axo','pid=,ppid=,rss='],text=True)
        rows=[tuple(map(int,line.split())) for line in text.splitlines()]
        owned={process.pid}
        while True:
            children={pid for pid,parent,rss in rows if parent in owned}
            if children<=owned:break
            owned|=children
        samples.append({'seconds':time.monotonic()-started,'processes':len(owned),'rss_bytes':sum(rss*1024 for pid,parent,rss in rows if pid in owned)})
        if time.monotonic()-started>390:
            process.terminate();raise SystemExit('Profile timed out')
        time.sleep(.2)
    status=process.returncode
report={'scope':'sampled sum of resident memory for app plus worker/probe descendants; shared pages may be counted more than once',
    'exit_code':status,'peak_sampled_rss_bytes':max(s['rss_bytes'] for s in samples),'max_processes':max(s['processes'] for s in samples),'samples':samples}
(root/'build/enrichment-memory.json').write_text(json.dumps(report,indent=2)+'\n')
print(out.read_text());print(json.dumps({k:v for k,v in report.items() if k!='samples'}))

if status:raise SystemExit(f'Profile failed ({status}); measurements retained')
