#!/usr/bin/env python3
"""Extract one Foresight business FileDescriptorProto without executing the app.
Requires Python standard library only. No network, installation, or executable copy.
Default reads installed app tar member directly into memory; --helper reads an
already extracted Helper. Offsets always address uncompressed Helper bytes.
"""
import argparse, hashlib, json, tarfile
from pathlib import Path
EXPECTED_SHA256='c96e3fbbd5769932dc5dac04b95a185af06f9e40eb2b51a7168841b7c69c1a0e'
MEMBER='research/xeno/labs/foresight/launch_agent/ForesightHelper'
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--app',default='/Applications/Foresight.app',help='installed Foresight.app package')
parser.add_argument('--helper',help='optional already extracted Helper path')
parser.add_argument('--output',type=Path,default=Path(__file__).resolve().parent.parent/'03-接口与数据')
args=parser.parse_args();out=args.output;out.mkdir(parents=True,exist_ok=True)
if args.helper:
 helper=Path(args.helper);b=helper.read_bytes()
else:
 archive=Path(args.app)/'Contents/Resources/ForesightHelper_tar.tar'
 with tarfile.open(archive) as tf:
  member=tf.getmember(MEMBER)
  if not member.isfile():raise SystemExit('Expected regular Helper tar member')
  b=tf.extractfile(member).read()
 helper=str(archive)+'!/'+MEMBER
actual_hash=hashlib.sha256(b).hexdigest()
if actual_hash!=EXPECTED_SHA256:
 raise SystemExit('Helper SHA256 mismatch: '+actual_hash+'; this script targets the verified build only.')
needle=b'research/xeno/labs/foresight/launch_agent/proto/rag_service.proto'
start=0x3138698
if b[start:start+2]!=b'\x0a\x41' or b[start+2:start+2+len(needle)]!=needle:
 raise SystemExit('Expected descriptor at verified file offset 0x3138698')
def var(buf,p):
 n=s=0
 while True:
  c=buf[p];p+=1;n|=(c&127)<<s;s+=7
  if c<128:return n,p
  assert s<=70

def wire(buf,base=0,stopzero=False):
 res=[];p=0
 while p<len(buf):
  k,q=var(buf,p)
  if k==0 and stopzero:return res,p
  assert k>0
  w=k&7;f=k>>3
  if w==0:v,e=var(buf,q);dp=q
  elif w==2:n,dp=var(buf,q);e=dp+n;v=buf[dp:e];assert e<=len(buf)
  elif w in [1,5]:dp=q;e=q+(8 if w==1 else 4);v=buf[q:e]
  else:raise ValueError((p,k))
  res.append(dict(field=f,wire=w,value=v,offset=base+p,data_offset=base+dp));p=e
 return res,p

def get(r,f,default=None):return next((x['value'] for x in r if x['field']==f),default)
def txt(x):return x.decode('utf-8') if isinstance(x,bytes) else x
r,n=wire(b[start:start+12000],start,True);raw=b[start:start+n]
(out/'rag-service.descriptor.bin').write_bytes(raw)
T={1:'double',2:'float',3:'int64',4:'uint64',5:'int32',6:'fixed64',7:'fixed32',8:'bool',9:'string',10:'group',11:'message',12:'bytes',13:'uint32',14:'enum',15:'sfixed32',16:'sfixed64',17:'sint32',18:'sint64'}
result={'evidence_type':'exact_structured_extraction','source':str(helper),'file_offset':hex(start),'byte_length':n,'sha256':hashlib.sha256(raw).hexdigest(),'name':txt(get(r,1)),'package':txt(get(r,2)),'syntax':txt(get(r,12)),'edition_numeric':get(r,14),'messages':[],'services':[],'limitations':['File/custom options and source comments are not reconstructed in readable proto; raw descriptor preserves them.','No runtime or handler behavior established by descriptor.','Only this business descriptor is decoded; unrelated SDK protos are excluded.']}
for a in r:
 if a['field']==4:
  m,_=wire(a['value'],a['data_offset']);msg={'name':txt(get(m,1)),'source_offset':hex(a['offset']),'fields':[],'oneofs':[]}
  for c in m:
   if c['field']==8:oo,_=wire(c['value'],c['data_offset']);msg['oneofs'].append(txt(get(oo,1)))
   if c['field']==2:
    f,_=wire(c['value'],c['data_offset']);msg['fields'].append({'name':txt(get(f,1)),'number':get(f,3),'label':{1:'optional',2:'required',3:'repeated'}.get(get(f,4)),'type':T.get(get(f,5)),'type_name':txt(get(f,6)),'oneof_index':get(f,9),'source_offset':hex(c['offset'])})
  result['messages'].append(msg)
 if a['field']==6:
  s,_=wire(a['value'],a['data_offset']);svc={'name':txt(get(s,1)),'source_offset':hex(a['offset']),'methods':[]}
  for c in s:
   if c['field']==2:
    m,_=wire(c['value'],c['data_offset']);svc['methods'].append({'name':txt(get(m,1)),'input':txt(get(m,2)),'output':txt(get(m,3)),'client_streaming':bool(get(m,5,0)),'server_streaming':bool(get(m,6,0)),'source_offset':hex(c['offset'])})
  result['services'].append(svc)
result['helper_sha256']=actual_hash
result['verification']={'end_offset_exclusive':hex(start+n),'all_wire_fields_consumed':True,'message_names_unique':True,'message_field_numbers_and_names_unique':True,'rpc_names_unique':True,'counts':{'messages':len(result['messages']),'fields':sum(len(m['fields']) for m in result['messages']),'rpc':sum(len(s['methods']) for s in result['services'])}}
assert n==3578 and start==0x3138698
assert len(result['messages'])==22 and sum(len(m['fields']) for m in result['messages'])==45
assert sum(len(s['methods']) for s in result['services'])==11
assert len({m['name'] for m in result['messages']})==len(result['messages'])
for m in result['messages']:
 assert len({f['number'] for f in m['fields']})==len(m['fields'])
 assert len({f['name'] for f in m['fields']})==len(m['fields'])
for s in result['services']:assert len({m['name'] for m in s['methods']})==len(s['methods'])
(out/'rag-service-descriptor.json').write_text(json.dumps(result,ensure_ascii=False,indent=2))
lines=['// Readable reconstruction of embedded descriptor, NOT recovered source.','// All field numbers/types and RPC mappings are decoded. Custom options omitted.','// Edition mapping: https://raw.githubusercontent.com/protocolbuffers/protobuf/main/src/google/protobuf/descriptor.proto','edition = "2024";' ,f'package {result["package"]};','']
for m in result['messages']:
 lines.append('message '+m['name']+' {')
 def fs(f):return ('repeated ' if f['label']=='repeated' else '')+(f['type_name'] or f['type'])+' '+f['name']+' = '+str(f['number'])+'; // source '+f['source_offset']
 for f in m['fields']:
  if f['oneof_index'] is None:lines.append('  '+fs(f))
 for i,name in enumerate(m['oneofs']):
  lines.append('  oneof '+name+' {');lines.extend('    '+fs(f) for f in m['fields'] if f['oneof_index']==i);lines.append('  }')
 lines.append('}\n')
for s in result['services']:
 lines.append('service '+s['name']+' {');lines.extend('  rpc '+m['name']+' ('+m['input']+') returns ('+m['output']+'); // source '+m['source_offset'] for m in s['methods']);lines.append('}')
(out/'rag-service-readable.proto').write_text('\n'.join(lines))

print(json.dumps({'source':str(helper),'helper_sha256':actual_hash,'descriptor_offset':hex(start),'descriptor_length':n,'descriptor_sha256':result['sha256'],'counts':result['verification']['counts'],'output':str(out)},ensure_ascii=False,indent=2))
