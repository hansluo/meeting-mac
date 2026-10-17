import io,json,hashlib,tarfile
from pathlib import Path
pkg=Path(__file__).resolve().parent.parent
d= pkg/'03-接口与数据';import argparse
parser=argparse.ArgumentParser(description='Independent verification of delivered RAG descriptor using only Python standard library.')
parser.add_argument('--reproduced',type=Path,required=True,help='output directory from extract-rag-descriptor.py')
parser.add_argument('--app',type=Path,default=Path('/Applications/Foresight.app'))
args=parser.parse_args();rep=args.reproduced
raw=(d/'rag-service.descriptor.bin').read_bytes();recovered=json.load(open(d/'rag-service-descriptor.json'))
assert raw==(rep/'rag-service.descriptor.bin').read_bytes()
assert (d/'rag-service-readable.proto').read_bytes()==(rep/'rag-service-readable.proto').read_bytes()
with tarfile.open(args.app/'Contents/Resources/ForesightHelper_tar.tar') as archive:
 helper=archive.extractfile('research/xeno/labs/foresight/launch_agent/ForesightHelper').read()
assert hashlib.sha256(helper).hexdigest()=='c96e3fbbd5769932dc5dac04b95a185af06f9e40eb2b51a7168841b7c69c1a0e'
assert helper[0x3138698:0x3138698+3578]==raw
parsed_records=0
# Independent reader, not imported from extraction script.
def read_message(payload):
 global parsed_records
 stream=io.BytesIO(payload);fields=[]
 def u():
  value=0
  for shift in range(0,70,7):
   one=stream.read(1)
   assert len(one)==1
   byte=one[0];value+= (byte%128)*2**shift
   if byte<128:return value
  raise AssertionError('oversized varint')
 while stream.tell()<len(payload):
  tag=u();number,wire=divmod(tag,8);assert number>0
  if wire==0:value=u()
  elif wire==2:
   size=u();value=stream.read(size);assert len(value)==size
  elif wire in (1,5):
   size={1:8,5:4}[wire];value=stream.read(size);assert len(value)==size
  else:raise AssertionError('Unsupported wire')
  fields.append((number,value));parsed_records+=1
 assert stream.tell()==len(payload)
 return fields

def single(fields,num,default=None):
 hits=[v for n,v in fields if n==num];assert len(hits)<=1;return hits[0] if hits else default
root=read_message(raw);assert len([v for n,v in root if n==4])==22;assert len([v for n,v in root if n==6])==1
seen_msg=[];total=0
for serialized in [v for n,v in root if n==4]:
 m=read_message(serialized);name=single(m,1).decode();seen_msg.append(name)
 expected=next(m for m in recovered['messages'] if m['name']==name)
 fields=[]
 for serialized_field in [v for n,v in m if n==2]:
  f=read_message(serialized_field);record=(single(f,1).decode(),single(f,3),single(f,4),single(f,5),single(f,6),single(f,9));fields.append(record)
  e=next(e for e in expected['fields'] if e['name']==record[0]);assert record[1]==e['number'];assert {1:'optional',2:'required',3:'repeated'}[record[2]]==e['label'];assert record[5]==e['oneof_index'];assert (record[4].decode() if record[4] else None)==e['type_name'];assert {1:'double',5:'int32',8:'bool',9:'string',11:'message',12:'bytes'}[record[3]]==e['type']
  assert helper[int(e['source_offset'],16)]==0x12
 assert len(fields)==len(expected['fields']);assert len(set(f[0] for f in fields))==len(fields);assert len(set(f[1] for f in fields))==len(fields);total+=len(fields)
assert len(set(seen_msg))==22 and total==45
svc=read_message(next(v for n,v in root if n==6));rpc=[]
for serialized_method in [v for n,v in svc if n==2]:
 method=read_message(serialized_method);name=single(method,1).decode();rpc.append(name);e=next(m for m in recovered['services'][0]['methods'] if m['name']==name)
 assert single(method,2).decode()==e['input'];assert single(method,3).decode()==e['output'];assert bool(single(method,5,0))==e['client_streaming'];assert bool(single(method,6,0))==e['server_streaming']
assert len(rpc)==len(set(rpc))==11
verification={'source':str(args.app/'Contents/Resources/ForesightHelper_tar.tar'),'member':'research/xeno/labs/foresight/launch_agent/ForesightHelper','helper_sha256':hashlib.sha256(helper).hexdigest(),'descriptor_file_offset':'0x3138698','descriptor_byte_length':3578,'end_offset_exclusive':hex(0x3138698+3578),'descriptor_sha256':hashlib.sha256(raw).hexdigest(),'messages':22,'fields':45,'rpc':11,'independent_parser_wire_records_consumed':parsed_records,'checks':['Installed tar member bytes equal delivered descriptor exactly.','Independent BytesIO protobuf wire reader consumes descriptor and nested records through end without trailing bytes.','All 22 message names unique; per message field names/numbers unique; all 45 fields present in JSON.','All 11 RPC names unique and request/response/streaming mapping matches JSON.','Reproduction script produces identical descriptor bytes and readable proto.'],'limitations':['Independent parser shares the published protobuf field-number semantics; no third-party decoder used.','Readable proto compilation and custom options semantics not verified.']}
(pkg/'05-证据与复现/rag-descriptor-verification.json').write_text(json.dumps(verification,ensure_ascii=False,indent=2));print(json.dumps(verification,indent=2))
