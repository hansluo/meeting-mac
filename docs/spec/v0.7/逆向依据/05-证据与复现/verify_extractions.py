"""Verify delivered text against immutable bytes of the selected installed app.

Standard library only. Does not execute the target or read personal app data.
"""
import hashlib
import json
from pathlib import Path
import tarfile

ROOT = Path(__file__).resolve().parents[1]
MAIN_PATH = Path('/Applications/Foresight.app/Contents/MacOS/Foresight')
MAIN = MAIN_PATH.read_bytes()
assert hashlib.sha256(MAIN).hexdigest() == 'fa98b856bfbe9b40cdebfb9f975f7867ec5c0a3ca75b81214a096a60b6db8326'
with tarfile.open('/Applications/Foresight.app/Contents/Resources/ForesightHelper_tar.tar') as archive:
    HELPER = archive.extractfile('research/xeno/labs/foresight/launch_agent/ForesightHelper').read()
assert hashlib.sha256(HELPER).hexdigest() == 'c96e3fbbd5769932dc5dac04b95a185af06f9e40eb2b51a7168841b7c69c1a0e'


def load(relative):
    return json.loads((ROOT / relative).read_text(encoding='utf-8'))


def verify_row(row, data=MAIN):
    offset = int(row.get('data_offset', row.get('file_offset')), 16)
    raw = data[offset:offset + row['byte_length']]
    assert len(raw) == row['byte_length']
    encoding = row.get('encoding', 'utf-8')
    assert raw.decode(encoding) == row['text']
    if 'raw_sha256' in row:
        assert hashlib.sha256(raw).hexdigest() == row['raw_sha256']


strings = load('05-证据与复现/dart-string-objects.json')
for row in strings:
    verify_row(row)
prompts = load('01-内置提示词/提示词索引.json')
assert len(prompts) == 20
for row in prompts:
    verify_row(row)
    assert (ROOT / '01-内置提示词' / row['raw_file']).read_text(encoding='utf-8') == row['text']
fragments = load('01-内置提示词/动态拼接片段.json')
templates = load('01-内置提示词/运行时对话模板/索引.json')
for row in fragments + templates:
    verify_row(row)
mechanisms = load('02-产品与架构/产品机制证据.json')['items']
for row in mechanisms:
    verify_row(row)
contracts = load('03-接口与数据/contracts-and-data-evidence.json')
contract_strings = 0
for group in ('rpc_paths', 'database_class_candidates', 'ffi_name_strings', 'lifecycle_strings', 'sql_statements'):
    for row in contracts[group]:
        verify_row(row, HELPER if 'ForesightHelper' in row['source'] else MAIN)
        contract_strings += 1
valid_json = 0
for path in ROOT.rglob('*.json'):
    json.loads(path.read_text(encoding='utf-8'))
    valid_json += 1
report = dict(
    status='pass',
    main_sha256=hashlib.sha256(MAIN).hexdigest(),
    helper_sha256=hashlib.sha256(HELPER).hexdigest(),
    verified=dict(candidate_strings=len(strings), business_prompt_items=len(prompts),
                  dynamic_fragments=len(fragments), runtime_templates=len(templates),
                  mechanism_strings=len(mechanisms), contract_strings=contract_strings,
                  json_documents=valid_json),
    limitations=['Byte accuracy does not establish runtime reachability or behavior.',
                 'Candidate Dart object layout is inferred for this exact build.',
                 'RPC descriptor has a separate independent wire verification report.'])
(ROOT / '05-证据与复现/最终提取校验.json').write_text(json.dumps(report, indent=2), encoding='utf-8')
print(json.dumps(report, indent=2))
