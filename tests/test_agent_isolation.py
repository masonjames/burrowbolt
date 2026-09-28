#!/usr/bin/env python3
"""Opt-in installed-Codex protocol check. No model turn or tool action is sent."""
import json,selectors,shutil,subprocess,time
flags=['apps','plugins','hooks','shell_tool','unified_exec','memories','multi_agent','computer_use','browser_use','browser_use_external','image_generation','view_image']
args=[shutil.which('codex') or 'codex','app-server','-c','web_search="disabled"','-c','project_doc_max_bytes=0','-c','notify=[]']
for flag in flags:args+=['--disable',flag]
p=subprocess.Popen(args,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,text=True)
poll=selectors.DefaultSelector();poll.register(p.stdout,selectors.EVENT_READ)
def request(i,method,params):
    p.stdin.write(json.dumps(dict(id=i,method=method,params=params))+'\n');p.stdin.flush()
    until=time.monotonic()+20
    while time.monotonic()<until:
        if not poll.select(1):continue
        line=p.stdout.readline()
        assert line,'server exited'
        data=json.loads(line)
        if data.get('id')==i:
            assert 'error' not in data,data.get('error')
            return data['result']
    raise RuntimeError('server timeout')
try:
    request(1,'initialize',dict(clientInfo=dict(name='burrowbolt-isolation-check',version='1')))
    config=request(4,'config/read',dict(includeLayers=False,cwd='/private/tmp'))['config']
    blocked={name:{'enabled':False} for name in config.get('mcp_servers',{})}
    result=request(2,'thread/start',dict(cwd='/private/tmp',sandbox='read-only',approvalPolicy='never',ephemeral=True,config={'mcp_servers':blocked}))
    servers=request(5,'mcpServerStatus/list',dict(threadId=result['thread']['id']))
    rows=servers['data']
    summary={'configured_servers':len(blocked),'runtime_states':sorted(set(s.get('runtimeStatus','unknown') for s in rows)),
             'exposed_tools':sum(len(s['tools']) for s in rows)}
    print(json.dumps(summary))
    assert not servers.get('nextCursor') and all(s.get('runtimeStatus')=='disabled' and not s['tools'] for s in rows)
    print('PASS: inherited MCP servers disabled before any model turn; no external action or inference performed')
finally:
    p.terminate();p.wait(timeout=5)
