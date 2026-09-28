#!/usr/bin/env python3
"""Retained paired rounds: investigate >5%; block repeatable regressions, never waive smaller ones."""
import csv,json,pathlib,shutil,subprocess,tempfile
ROOT=pathlib.Path(__file__).resolve().parents[1]
baseline=json.loads((ROOT/'UPSTREAMS.lock').read_text())['performance_baseline']
def run(*args): subprocess.run(args,cwd=ROOT,check=True)
def repeatable(ratios): return sum(ratio>1.05 for ratio in ratios)>=2
assert not repeatable([1.06,1,1]) and repeatable([1.06,1.07,1])
rounds=[]
with tempfile.TemporaryDirectory(prefix='burrowbolt-performance-') as folder:
    path=pathlib.Path(folder)
    wide=path/'wide';wide.mkdir()
    for i in range(50000): (wide/str(i)).write_bytes(b'fixture')
    deep=path
    for i in range(200):
        deep=deep/'d';deep.mkdir();(deep/'file').write_bytes(b'fixture')
    run('python3','benchmarks/first-map.py','--baseline',baseline,'--path',folder,'--build-only')
    old=ROOT/'build/perf-baseline-source'
    subprocess.run(['cargo','build','--locked','--release','--features','cli','--bin','bench'],cwd=old,check=True)
    run('python3','benchmarks/rendering.py','--baseline',baseline,'--build-only','--output','build/performance-renderer')
    # A fixed three rounds (not retry-until-green) distinguish repeatable changes
    # from hosted scheduling spikes. Every round and every AB/BA pair is retained.
    for number in range(1,4):
        run('python3','benchmarks/first-map.py','--baseline',baseline,'--path',folder,'--runs','21','--skip-build')
        scan_path=f'build/perf-results/scan-{number}.json'
        run('python3','benchmarks/scan.py','--baseline',str(old/'target/release/bench'),
            '--candidate','target/release/bench','--path',folder,'--runs','21','--output',scan_path)
        shutil.copyfile(ROOT/'build/first-map/results.json',ROOT/f'build/perf-results/first-map-{number}.json')
        render=subprocess.check_output([str(ROOT/'build/performance-renderer')],cwd=ROOT,text=True)
        (ROOT/f'build/performance-rendering-{number}.txt').write_text(render);print(render)
        scan=json.loads((ROOT/scan_path).read_text())['summary']
        first=json.loads((ROOT/'build/first-map/results.json').read_text())['summary']
        ratios={'scan':scan['candidate']['median_seconds']/scan['baseline']['median_seconds'],
                'first-map':first['candidate']['seconds']/first['baseline']['seconds']}
        for row in csv.reader(render.splitlines()):
            if len(row)==4 and row[0].startswith(('treemap_','sunburst_')):
                ratios[row[0]]=float(row[2])/float(row[1])
        rounds.append(ratios);print(json.dumps({'round':number,'ratios':ratios},indent=2))
blocked=[name for name in rounds[0] if repeatable([r[name] for r in rounds])]
spikes=[name for name in rounds[0] if any(r[name]>1.05 for r in rounds)]
report={'rounds':rounds,'repeatable_regressions':blocked,'investigation_spikes':spikes}
(ROOT/'build/performance-ratios.json').write_text(json.dumps(report,indent=2)+'\n')
if spikes: print('::warning::Performance investigation signals retained: '+', '.join(spikes))
assert not blocked, 'Repeatable performance investigation required: '+', '.join(blocked)
