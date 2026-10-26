#!/usr/bin/env python3
"""统计中文字面量分布：哪些 Swift 文件里还有直接写死的中文 UI 文案。"""
import re, os, sys

CJK = re.compile(r'[\u4e00-\u9fff]')
ROOT = '/tmp/om-fix-b1/src/ios'

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

# 匹配字符串字面量（不含插值内部）
STR = re.compile(r'"((?:[^"\\\n]|\\.)*)"')

rows = []
for dirpath, _, files in os.walk(ROOT):
    for f in files:
        if not f.endswith('.swift'): continue
        p = os.path.join(dirpath, f)
        try:
            src = open(p, encoding='utf-8').read()
        except Exception:
            continue
        src2 = strip_comments(src)
        hits = []
        for m in STR.finditer(src2):
            lit = m.group(1)
            if not CJK.search(lit): continue
            # 前后 40 字符看是不是 AppLocalized / NSLocalizedString / 日志
            pre = src2[max(0, m.start()-60):m.start()]
            if 'AppLocalized' in pre[-30:] or 'LocalizedStringResource' in pre[-40:]:
                continue
            line = src2[:m.start()].count('\n') + 1
            if re.search(r'logger\.|print\(|assert|fatalError', pre[-40:]):
                continue
            hits.append((line, lit[:40]))
        if hits:
            rows.append((len(hits), p.replace(ROOT + '/', ''), hits))

rows.sort(reverse=True)
total = sum(r[0] for r in rows)
print(f'文件数 {len(rows)}，中文 UI 字面量总数 {total}\n')
for cnt, p, hits in rows[:25]:
    print(f'{cnt:4d}  {p}')
if len(sys.argv) > 1 and sys.argv[1] == 'detail':
    print('\n--- 明细 ---')
    for cnt, p, hits in rows:
        print(f'\n## {p} ({cnt})')
        for line, lit in hits:
            print(f'  :{line}  {lit}')
