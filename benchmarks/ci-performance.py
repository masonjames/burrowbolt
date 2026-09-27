#!/usr/bin/env python3
"""Paired checks on a fixed fixture; >5% blocks for investigation, never waives smaller regressions."""
import csv,json,pathlib,subprocess,tempfile
ROOT=pathlib.Path(__file__).resolve().parents[1]
baseline=json.loads((ROOT/'UPSTREAMS.lock').read_text())['performance_baseline']
def run(*args): subprocess.run(args,cwd=ROOT,check=True)
with tempfile.TemporaryDirectory(prefix='burrowbolt-performance-') as folder:
    path=pathlib.Path(folder)
    wide=path/'wide';wide.mkdir()
    for i in range(50000): (wide/str(i)).write_bytes(b'fixture')
    deep=path
    for i in range(200):
        deep=deep/'d';deep.mkdir();(deep/'file').write_bytes(b'fixture')
    run('python3','benchmarks/first-map.py','--baseline',baseline,'--path',folder,'--runs','7')
    old=ROOT/'build/perf-baseline-source'
    subprocess.run(['cargo','build','--locked','--release','--features','cli','--bin','bench'],cwd=old,check=True)
    run('python3','benchmarks/scan.py','--baseline',str(old/'target/release/bench'),
        '--candidate','target/release/bench','--path',folder,'--runs','9','--output','build/perf-results/ci.json')
render=subprocess.check_output(['python3','benchmarks/rendering.py','--baseline',baseline],cwd=ROOT,text=True)
(ROOT/'build/performance-rendering.txt').write_text(render);print(render)
scan=json.loads((ROOT/'build/perf-results/ci.json').read_text())['summary']
first=json.loads((ROOT/'build/first-map/results.json').read_text())['summary']
ratios={'scan':scan['candidate']['median_seconds']/scan['baseline']['median_seconds'],
        'first-map':first['candidate']['seconds']/first['baseline']['seconds']}
for row in csv.reader(render.splitlines()):
    if len(row)==4 and row[0].startswith(('treemap_','sunburst_')):
        ratios[row[0]]=float(row[2])/float(row[1])
(ROOT/'build/performance-ratios.json').write_text(json.dumps(ratios,indent=2)+'\n')
print(json.dumps(ratios,indent=2))
assert all(ratio<=1.05 for ratio in ratios.values()), 'Performance investigation required; inspect paired samples before merge'
