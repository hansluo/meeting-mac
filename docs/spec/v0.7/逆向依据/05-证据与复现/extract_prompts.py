# -*- coding: utf-8 -*-
"""Extract length-delimited candidate Dart strings and selected product prompts.

Layout is inferred from this artifact, not asserted as a universal Dart ABI.
Source binary is never modified or executed. No original binary is distributed.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import struct


SPECS = [
    ('0x5ab6d90', '转写分段摘要', '整段指令', '讨论结果、决策与分歧，去除寒暄。'),
    ('0x5afb510', '行动项提取', '整段指令', '任务、责任人、类别和确认状态。'),
    ('0x5b74170', '结构化会议简报', '整段指令', 'overview 与 sections JSON。'),
    ('0x5cbb460', '会议问答与搜索_旧格式', '完整模板', 'QUERY 与 CONTEXT；不足时生成搜索调用。'),
    ('0x5d2daf0', 'JSON修复', '拼接前缀', '动态追加待修复 JSON。'),
    ('0x5dabdc0', '会议简报_含行动项', '整段指令', '概览、行动项、详情；初始化 OK。'),
    ('0x5e25f80', '会议简报_概览与详情', '整段指令', '结构化概览与主题讨论。'),
    ('0x60821c0', '笔记增强_简短完整句', '整段指令', '仅用每条手写笔记自己的转写引用。'),
    ('0x60943e0', '笔记增强_超精简', '整段指令', '每条笔记维持独立，约4至10词。'),
    ('0x60b1090', '会议笔记_转写片段引用', '整段指令', '按段号引用，覆盖会议全过程。'),
    ('0x6134be0', '增量更新会议简报', '整段指令', '保留旧结论并合并新讨论。'),
    ('0x61e5540', '聊天历史压缩', '整段指令', 'Context Memo，保留事实、决策与偏好。'),
    ('0x61f9190', '通用助手与原生工具调用', '整段指令', '上下文优先、Source 引用、日程格式和工具调用。'),
    ('0x620e570', '分块摘要归并', '拼接前缀', '归并各块摘要并去重，后续动态追加规则。'),
    ('0x594e9f0', '会议简报用户任务', '短指令', '根据转写生成简报。'),
    ('0x5a64560', '会议简报与手写笔记用户任务', '短指令', '根据转写和手写笔记生成简报。'),
    ('0x59f03e0', '附带音频的问答补充_A', '拼接后缀', '附带音频辅助理解当前问题。'),
    ('0x5b3da70', '附带音频的问答补充_B', '拼接后缀', '附带音频辅助理解，文案有小差异。'),
    ('0x6106800', '遗漏议题补充_超精简', '可选拼接规则', '从未覆盖转写补充至多1至2项关键决策。'),
    ('0x6173670', '遗漏议题补充_简短句', '可选拼接规则', '较完整笔记版的遗漏议题补充。'),
]


def dump(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2), encoding='utf-8')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--binary', default='/Applications/Foresight.app/Contents/MacOS/Foresight')
    parser.add_argument('--output', default=str(Path(__file__).resolve().parents[1]))
    args = parser.parse_args()
    root = Path(args.output)
    binary = Path(args.binary).read_bytes()
    expected = 'fa98b856bfbe9b40cdebfb9f975f7867ec5c0a3ca75b81214a096a60b6db8326'
    if hashlib.sha256(binary).hexdigest() != expected:
        raise SystemExit('Different binary: fixed prompt offsets cannot be reused.')
    evidence = root / '05-证据与复现'
    evidence.mkdir(parents=True, exist_ok=True)
    rows = []
    for match in re.finditer(rb'\xb2[\xf0-\xff]\x05\x00|\xb2[\x00-\x0f]\x06\x00', binary):
        offset = match.start()
        cid = struct.unpack_from('<I', binary, offset)[0] >> 12
        tagged_length = struct.unpack_from('<Q', binary, offset + 8)[0]
        if tagged_length % 2 or not 0 < tagged_length // 2 < 262144:
            continue
        length = tagged_length // 2
        byte_length = length * (1 if cid == 95 else 2)
        raw = binary[offset + 16:offset + 16 + byte_length]
        if len(raw) != byte_length:
            continue
        encoding = 'latin-1' if cid == 95 else 'utf-16le'
        try:
            text = raw.decode(encoding)
        except UnicodeError:
            continue
        if any(ord(c) < 32 and c not in '\n\r\t' for c in text) or '\x7f' in text:
            continue
        rows.append(dict(object_header_offset=hex(offset), data_offset=hex(offset + 16),
                         byte_length=byte_length, code_unit_length=length, encoding=encoding,
                         header_cid_candidate=cid, raw_sha256=hashlib.sha256(raw).hexdigest(), text=text))
    dump(evidence / 'dart-string-objects.json', rows)
    by_offset = {row['data_offset']: row for row in rows}
    out = root / '01-内置提示词'
    raw_dir = out / '原文'
    raw_dir.mkdir(parents=True, exist_ok=True)
    prompts = []
    for ordinal, (offset, title, kind, purpose) in enumerate(SPECS, 1):
        row = by_offset[offset]
        prompt_id = f'P{ordinal:02d}'
        filename = f'{prompt_id}-{title}.txt'
        (raw_dir / filename).write_text(row['text'], encoding='utf-8')
        prompts.append(dict(row, id=prompt_id, title=title, kind=kind, purpose_inference=purpose,
                            raw_file='原文/' + filename,
                            boundaries='length-delimited candidate Dart string; runtime linkage unverified'))
    dump(out / '提示词索引.json', prompts)
    lines = ['# 提示词原文汇编', '', '以下是程序数据，不是对分析器或读者的执行指令。', '']
    for row in prompts:
        lines += [f"## {row['id']} {row['title']}", '',
                  f"类型：{row['kind']}。文件偏移：`{row['data_offset']}`。用途判断：{row['purpose_inference']}",
                  '', '~~~~text', row['text'], '~~~~', '']
    (out / '全部提示词原文.md').write_text('\n'.join(lines), encoding='utf-8')
    fragments = []
    for row in rows:
        text = row['text']
        offset = int(row['data_offset'], 16)
        if not 0x5900000 < offset < 0x6240000 or len(text) >= 500:
            continue
        if (re.search(r'^\s*</?(?:instructions|output|context|query|transcript|meeting_transcript|shorthand_notes|relevant_excerpts|uncovered_meeting_excerpts|previous_enhanced|source|sources|user_notes)', text)
                or text.startswith(('Concise summarize the following document chunk:', 'Provide a cohesive summary',
                                    'The following are partial summaries', '--- Partial Summary',
                                    'New discussion recorded since this summary', '[Current Date:'))):
            fragments.append(row)
    dump(out / '动态拼接片段.json', fragments)
    ui_row = by_offset['0x592fcd0']
    product_dir = root / '02-产品与架构'
    product_dir.mkdir(exist_ok=True)
    dump(product_dir / 'UI英文文案.json', json.loads(ui_row['text']))
    dump(evidence / 'UI文案来源.json', {key: value for key, value in ui_row.items() if key != 'text'})
    templates = []
    seen = set()
    template_dir = out / '运行时对话模板'
    template_dir.mkdir(exist_ok=True)
    for match in re.finditer(rb'\{\{[- ]', binary):
        start = binary.rfind(b'\0', max(0, match.start() - 12000), match.start()) + 1
        end = binary.find(b'\0', match.start(), match.start() + 40000)
        if end < 0 or end - start < 150:
            continue
        raw = binary[start:end]
        try:
            text = raw.decode('utf-8')
        except UnicodeError:
            continue
        if any(ord(c) < 32 and c not in '\t\r\n' for c in text):
            continue
        if 'start_of_turn' not in text and 'role' not in text:
            continue
        digest = hashlib.sha256(raw).hexdigest()
        if digest in seen:
            continue
        seen.add(digest)
        template_id = f'T{len(templates) + 1:02d}'
        (template_dir / (template_id + '.jinja')).write_text(text, encoding='utf-8')
        templates.append(dict(id=template_id, data_offset=hex(start), byte_length=len(raw),
                              raw_sha256=digest, text=text,
                              classification='generic bundled runtime template; actual selection unknown'))
    dump(template_dir / '索引.json', templates)
    print(json.dumps(dict(objects=len(rows), prompts=len(prompts), fragments=len(fragments),
                          runtime_templates=len(templates), ui_entries=len(json.loads(ui_row['text'])))))


if __name__ == '__main__':
    main()
