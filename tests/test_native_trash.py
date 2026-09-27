#!/usr/bin/env python3
"""Opt-in macOS integration check. Only creates/removes its own uniquely named fixture."""
import json, pathlib, shutil, subprocess, tempfile, uuid
ROOT = pathlib.Path(__file__).resolve().parents[1]

def main():
    # The real worker requires the real user's HOME. No existing Trash entry is read or removed.
    base = pathlib.Path.home() / 'Library/Caches/com.masonjames.burrowbolt.fixture'
    base.mkdir(parents=True, exist_ok=True)
    fixture = pathlib.Path(tempfile.mkdtemp(prefix='native-trash-', dir=base))
    selected = fixture / ('BurrowBolt-fixture-' + str(uuid.uuid4()) + '.dmg')
    kept = fixture / 'keep.dmg'
    selected.write_bytes(b'isolated BurrowBolt fixture'); kept.write_bytes(b'keep this fixture')
    process = subprocess.Popen([str(ROOT/'build/BurrowBolt.app/Contents/MacOS/burrowbolt-worker')],
                               stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
    request_id = 0
    def request(op, **body):
        nonlocal request_id
        request_id += 1
        process.stdin.write(json.dumps(dict(version=1,id=request_id,op=op,**body))+'\n'); process.stdin.flush()
        records=[]
        while True:
            # Each request emits only a handful of records; the worker enforces probe deadlines.
            line=process.stdout.readline()
            assert line, 'worker stopped'
            record=json.loads(line); assert record['id']==request_id
            assert record['event']!='error', record
            if record['event']=='done': return records
            records.append(record['body'])
    try:
        candidates=request('discover',root=str(fixture),generation='fixture',items=[
            dict(candidateID=key,path=str(path),category='installer',bytes=path.stat().st_size,complete=True)
            for key,path in [('selected',selected),('kept',kept)]])
        assert all(item['action']=='review' for item in candidates), candidates
        plan=request('plan',generation='fixture',candidateIDs=['selected'])[0]
        result=request('apply',generation='fixture',token=plan['token'],candidateIDs=['selected'])[0]
        assert result['status']=='trashed', result
        destination=pathlib.Path(result['trashPath'])
        assert not selected.exists() and destination.read_bytes()==b'isolated BurrowBolt fixture'
        assert kept.read_bytes()==b'keep this fixture'
        removed=request('empty',receipts=[result['receipt']],confirmedPermanentRemoval=True)[0]
        assert removed['status']=='removed' and not destination.exists(), removed
        assert kept.read_bytes()==b'keep this fixture'
        print('PASS: real Foundation Trash, exact selection, untouched sibling, and receipt-only permanent removal')
    finally:
        process.stdin.close()
        try: process.wait(timeout=5)
        except subprocess.TimeoutExpired: process.kill();process.wait()
        shutil.rmtree(fixture)
        try: base.rmdir()
        except OSError: pass
if __name__=='__main__': main()
