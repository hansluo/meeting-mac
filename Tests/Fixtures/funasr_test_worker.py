import json, os, sys, time
mode = os.path.basename(sys.argv[1]) if len(sys.argv) > 1 else 'normal'
def emit(d):
    print(json.dumps(d), flush=True)
if mode == 'startup_timeout': time.sleep(30)
if mode == 'noise': print('third party noise', flush=True)
if mode == 'oversized': print('x'*70000, flush=True)
if mode == 'broken_stdin': os.close(0)
emit({'version':1, 'type':'started', 'job_id':None})
if mode == 'broken_stdin': time.sleep(30); sys.exit(0)
for line in sys.stdin:
    r=json.loads(line); job=r['job_id']; op=r['op']
    if mode == 'crash': sys.exit(2)
    if op == 'probe': emit({'version':1,'job_id':job,'type':'probe','package_version':'fixture','device':'cpu','model_loaded':1 if mode == 'bad_probe' else False,'asr_verified':False})
    elif op == 'load': emit({'version':1,'job_id':job,'type':'ready'})
    elif op == 'transcribe':
        if mode == 'request_timeout': time.sleep(30)
        if mode == 'malformed': print('{invalid', flush=True); continue
        if mode == 'unknown_job': job='00000000-0000-0000-0000-000000000000'
        emit({'version':1,'job_id':job,'type':'result','text':'你好','raw_text':'<|zh|>你好','sample_count':16,'backend_fields':{}})
