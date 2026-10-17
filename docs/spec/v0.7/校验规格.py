from pathlib import Path
import hashlib,json,re,struct
r=Path(__file__).resolve().parents[1];b=r/'v0.7';spec=(r/'product-v0.7.md').read_text();req=json.loads((r/'requirements-v0.7.json').read_text())
checks={}
def check(name,value):
 checks[name]=bool(value)
 if not value:raise AssertionError(name)
check('draft_authority',req['implementation_authorized'] is False and req['status']=='draft_for_user_review')
fr=req['functional_requirements'];nfr=req['nonfunctional_requirements']
check('18_unique_FR',{x['id'] for x in fr}=={f'FR-{i:03}' for i in range(1,19)})
check('8_unique_NFR',{x['id'] for x in nfr}=={f'NFR-{i:03}' for i in range(1,9)})
check('18_unique_AC',{x['acceptance']['id'] for x in fr}=={f'AC-{i:03}' for i in range(1,19)})
for row in fr:
 aid=row['acceptance']['id']
 line=re.search(r'\*\*'+aid+r'：\*\*[^\n]+',spec).group(0)
 check(aid+'_scenario_refs_match',set(re.findall(r'UAT-\d{2}',line))==set(row['acceptance']['scenarios']))
check('38_canonical_scenarios',len(req['acceptance_scenarios'])==38 and len({x['id'] for x in req['acceptance_scenarios']})==38)

uat=set(re.findall(r'UAT-\d{2}',json.dumps(req)))
check('38_UAT_ids',uat=={f'UAT-{i:02}' for i in range(1,39)})
check('38_UAT_present_in_main_spec',uat<=set(re.findall(r'UAT-\d{2}',spec)))
check('12_UI_requirements',len(req['interface_requirements'])==12)
check('12_RP_contracts',{x['id'] for x in req['prompt_requirements']}=={f'RP-{i:02}' for i in range(1,13)})
check('all_prompt_contracts_embedded',all('### RP-'+f'{i:02}' in spec or '#### RP-'+f'{i:02}' in spec for i in range(1,13)))
items=json.loads((b/'逆向依据/01-内置提示词/提示词索引.json').read_text())
check('20_original_prompts',len(items)==20 and {x['id'] for x in items}=={f'P{i:02}' for i in range(1,21)})
for x in items:
 text=(b/'逆向依据/01-内置提示词'/x['raw_file']).read_text()
 check(x['id']+'_raw_text_preserved',text==x['text'])
 codec={'latin-1':'latin-1','utf-16le':'utf-16-le','utf-16-le':'utf-16-le'}[x['encoding']]
 check(x['id']+'_raw_byte_sha',hashlib.sha256(text.encode(codec)).hexdigest()==x['raw_sha256'])
 check(x['id']+'_embedded',x['text'] in spec)
check('20_dynamic_fragments',len(json.loads((b/'逆向依据/01-内置提示词/动态拼接片段.json').read_text()))==20)
check('503_mechanism_records',len(json.loads((b/'逆向依据/02-产品与架构/产品机制证据.json').read_text())['items'])==503)
check('69_module_entries',len(json.loads((b/'逆向依据/02-产品与架构/关键实现入口.json').read_text())['entries'])==69)
check('808_UI_strings',len(json.loads((b/'逆向依据/02-产品与架构/UI英文文案.json').read_text()))==808)
check('6_runtime_templates',len(list((b/'逆向依据/01-内置提示词/运行时对话模板').glob('*.jinja')))==6)
for x in json.loads((b/'截图证据索引.json').read_text()):
 data=(b/x['file']).read_bytes();check(x['id']+'_image_sha',hashlib.sha256(data).hexdigest()==x['sha256']);check(x['id']+'_dimensions',struct.unpack('>II',data[16:24])==(x['width_px'],x['height_px']))
check('both_screenshots_embedded',all(x in spec for x in ['![S01','![S02']))
for target in re.findall(r'!?\[[^\]]*\]\(([^)]+)\)',spec):
 if target.startswith(('https://','http://','#')):continue
 check('local_link_'+target,(r/target.split('#')[0]).exists())
check('UI_reference_and_unknowns_separate','可见未确认控件' in spec and '未观察到的Foresight页面' in spec)
check('P0_P1_P2_kept',all(x in spec for x in ['P0 核心可用版','P1 工作流完整版','P2 完整目标版']))
check('prompt_plan_architecture_in_main',all(x in spec for x in ['RP-12','D0 本次文档','AudioTrack/Segment','S01/S02','部分来源失效']))
check('no_obsolete_current_execution_claim','现可继续实现、资产准备' not in spec)
report={'spec_version':'0.7','status':'document_consistency_passed_application_not_tested','implementation_authorized':False,'counts':{'functional_requirements':18,'nonfunctional_requirements':8,'ui_requirements':12,'acceptance_scenarios':38,'original_prompts':20,'dynamic_fragments':20,'runtime_templates':6,'product_prompt_contracts':12},'checks':checks,'product_uat_passed':False,'scope':'Only document, asset hashes, identifiers and local links. No application build, install, model download or live UI test.'}
(r/'verification-v0.7.json').write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
print(json.dumps({'checks_passed':len(checks),'counts':report['counts'],'application_tested':False},ensure_ascii=False))
