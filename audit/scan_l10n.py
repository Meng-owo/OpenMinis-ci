#!/usr/bin/env python3
"""查中文字面量在 xcstrings 里有没有 key（UI 文案漏本地化）。"""
import re, os, json, sys

CJK = re.compile(r'[\u4e00-\u9fff]')
ROOT = '/tmp/om-fix-b1/src/ios'
STR = re.compile(r'"((?:[^"\\\n]|\\.)*)"')

catalog = json.load(open(os.path.join(ROOT, 'Localizable.xcstrings'), encoding='utf-8'))
keys = set(catalog.get('strings', {}).keys())

# 只查视图层（UI 文案），跳过测试与桥接工具
SKIP_DIRS = ('MinisTests/', 'BridgeCore/', 'Debug/', 'iSH/')

def strip_comments(s):
    out = []
    i = 0
    n = len(s)
    while i < n:
        c = s[i]
        if c == '/' and i + 1 < n and s[i+1] == '/':
            j = s.find('\n', i)
            if j < 0: break
            i = j
            continue
        if c == '/' and i + 1 < n and s[i+1] == '*':
            j = s.find('*/', i+2)
            if j < 0: break
            i = j + 2
            continue
        out.append(c)
        i += 1
    return ''.join(out)

rows = []
for dirpath, _, files in os.walk(ROOT):
    rel_dir = dirpath.replace(ROOT + '/', '')
    if any(rel_dir == d.rstrip('/') or rel_dir.startswith(d) for d in SKIP_DIRS):
        continue
    for f in files:
        if not f.endswith('.swift'): continue
        p = os.path.join(dirpath, f)
        rel = p.replace(ROOT + '/', '')
        try:
            src = open(p, encoding='utf-8').read()
        except Exception:
            continue
        src2 = strip_comments(src)
        misses = []
        for m in STR.finditer(src2):
            lit = m.group(1)
            if not CJK.search(lit): continue
            pre = src2[max(0, m.start()-50):m.start()]
            # 已经走本地化的
            if 'AppLocalized' in pre or 'LocalizedStringResource' in pre or 'NSLocalizedString' in pre:
                continue
            # 日志/断言/注释类
            if re.search(r'logger\.|print\(|assert|fatalError|precondition', pre[-40:]):
                continue
            if lit in keys:
                continue
            line = src2[:m.start()].count('\n') + 1
            misses.append((line, lit))
        if misses:
            rows.append((rel, misses))

rows.sort(key=lambda r: -len(r[1]))
total = sum(len(r[1]) for r in rows)
print(f'漏 key 的中文字面量 {total} 条，分布在 {len(rows)} 个文件\n')
for rel, ms in rows[:30]:
    print(f'{len(ms):4d}  {rel}')
if len(sys.argv) > 1 and sys.argv[1] == 'detail':
    print('\n--- 明细 ---')
    for rel, ms in rows:
        print(f'\n## {rel} ({len(ms)})')
        for line, lit in ms[:40]:
            print(f'  :{line}  {lit[:50]}')
