#!/usr/bin/env python3
"""批量翻译 UI 文案：把待补的中文写成 en 译文，插进 xcstrings。

用法：
  1) python3 export_need.py  -> /tmp/todo_<file>.json
  2) 调用 minis-model-use 翻译，结果按 {"zh": "...", "en": "..."} 列表
  3) python3 apply_trans.py /tmp/done_<file>.json
"""
import json, os, sys, re

ROOT = '/tmp/om-fix-b1/src/ios'
XC = os.path.join(ROOT, 'Localizable.xcstrings')

def load_work():
    return json.load(open('/tmp/cjk_work.json', encoding='utf-8'))['text']

def export(target_files, out):
    d = load_work()
    cat = json.load(open(XC, encoding='utf-8'))['strings']
    items = []
    for k, files in d.items():
        if not any(f in target_files for f in files):
            continue
        if k in cat:
            continue
        items.append({'zh': k, 'files': files})
    json.dump(items, open(out, 'w', encoding='utf-8'), ensure_ascii=False, indent=1)
    print(f'exported {len(items)} -> {out}')

def apply(path):
    rows = json.load(open(path, encoding='utf-8'))
    raw = open(XC, encoding='utf-8').read()
    existing = json.loads(raw)['strings']
    add = [r for r in rows if r['zh'] not in existing and r.get('en')]
    if not add:
        print('nothing to add'); return
    blocks = []
    for r in add:
        zh = json.dumps(r['zh'], ensure_ascii=False)
        en = json.dumps(r['en'], ensure_ascii=False)
        blocks.append(
            '    %s : {\n'
            '      "extractionState" : "manual",\n'
            '      "localizations" : {\n'
            '        "en" : {\n'
            '          "stringUnit" : {\n'
            '            "state" : "translated",\n'
            '            "value" : %s\n'
            '          }\n'
            '        },\n'
            '        "zh-Hans" : {\n'
            '          "stringUnit" : {\n'
            '            "state" : "translated",\n'
            '            "value" : %s\n'
            '          }\n'
            '        }\n'
            '      }\n'
            '    },\n' % (zh, en, zh)
        )
    anchor = '  "strings": {\n'
    i = raw.index(anchor) + len(anchor)
    out = raw[:i] + ''.join(blocks) + raw[i:]
    json.loads(out)
    open(XC, 'w', encoding='utf-8').write(out)
    print(f'inserted {len(add)}')

if __name__ == '__main__':
    if sys.argv[1] == 'export':
        export(sys.argv[2].split(','), sys.argv[3])
    else:
        apply(sys.argv[2])
