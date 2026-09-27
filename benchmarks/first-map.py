#!/usr/bin/env python3
"""Compile two production source snapshots and alternate first-map-ready measurements."""
import argparse,hashlib,json,pathlib,re,shutil,statistics,subprocess,tempfile
root=pathlib.Path(__file__).resolve().parents[1]
p=argparse.ArgumentParser();p.add_argument('--baseline',required=True);p.add_argument('--path',required=True);p.add_argument('--runs',type=int,default=5);p.add_argument('--build-only',action='store_true');p.add_argument('--skip-build',action='store_true');args=p.parse_args()
out=root/'build/first-map';out.mkdir(parents=True,exist_ok=True)
baseline=root/'build/perf-baseline-source'
if not args.skip_build:
    # Refuse to silently benchmark a stale or locally changed baseline snapshot.
    sha=subprocess.check_output(['git','rev-parse',args.baseline],cwd=root,text=True).strip()
    if not (baseline/'Cargo.toml').exists():
        baseline.mkdir(parents=True,exist_ok=True)
        with tempfile.TemporaryFile() as archive:
            subprocess.run(['git','archive',sha],cwd=root,stdout=archive,check=True)
            archive.seek(0);subprocess.run(['tar','-x','-C',str(baseline)],stdin=archive,check=True)
    for folder in ('app','src'):
        for file in (baseline/folder).rglob('*'):
            if file.is_file() and file.suffix in ('.swift','.rs','.h'):
                expected=subprocess.check_output(['git','show',sha+':'+str(file.relative_to(baseline))],cwd=root)
                assert file.read_bytes()==expected, 'Baseline source drift: '+str(file)
sparkle=subprocess.check_output(['python3','scripts/fetch-sparkle.py'],cwd=root,text=True).strip()
for name,source in ([] if args.skip_build else [('baseline',baseline),('candidate',root)]):
    subprocess.run(['cargo','build','--locked','--release','--lib'],cwd=source,check=True)
    stage=out/name;stage.mkdir(exist_ok=True)
    files=[]
    for file in sorted((source/'app').glob('*.swift')):
        if file.name=='Main.swift':continue
        text=re.sub(r'\bprivate\s+','',file.read_text())
        # Automated planning and enrichment begin after the measurement endpoint.
        destination=stage/file.name;destination.write_text(text);files.append(str(destination))
    subprocess.run(['swiftc',*([] if name=='baseline' else ['-D','BURROWBOLT_BENCHMARK']),*files,str(root/'benchmarks/FirstMap.swift'),'-O','-parse-as-library','-swift-version','6','-default-isolation','MainActor',
        '-import-objc-header',str(source/'app/bz.h'),'-target','arm64-apple-macos14.0','-L',str(source/'target/release'),'-lblitztree',
        '-F',sparkle,'-framework','Sparkle','-Xlinker','-rpath','-Xlinker',sparkle,'-framework','AppKit','-framework','SwiftUI','-o',str(stage/'first-map')],check=True)
if args.build_only:raise SystemExit(0)
rows=[]
for pair in range(args.runs+1):
    for name in (['baseline','candidate'] if pair%2==0 else ['candidate','baseline']):
        result=subprocess.run([str(out/name/'first-map'),args.path],capture_output=True,text=True,check=True,timeout=130)
        row={'build':name,'pair':pair,**json.loads(result.stdout)}
        if pair:rows.append(row);print(json.dumps(row),flush=True)
assert len({(r['nodes'],r['bytes'],r['scale']) for r in rows})==1,'Inputs changed; timings not comparable'
summary={name:{metric:statistics.median(r[metric] for r in rows if r['build']==name) for metric in ['seconds','max_main_loop_gap_ms']} for name in ['baseline','candidate']}
(out/'results.json').write_text(json.dumps({'scope':'offscreen first-map-ready; excludes visible-window paint and enrichment','path':args.path,'summary':summary,'measurements':rows,'binary_sha256':{name:hashlib.sha256((out/name/'first-map').read_bytes()).hexdigest() for name in ('baseline','candidate')}},indent=2)+'\n')
print(json.dumps(summary,indent=2))
