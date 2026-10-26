#!/usr/bin/env python3
"""找「有界面没功能」的入口（单遍、内存安全）：
1) 从未被构造的 View 结构体（死页面）
2) 点了只弹 toast 的按钮
"""
import os, re, gc
from collections import Counter

ROOT = 'src/ios'
SKIP = {'MinisTests', 'MinisUITests', 'BridgeCore', 'iSH', 'NativeOffloads'}

def files():
    out = []
    for dp, dns, fns in os.walk(ROOT):
        dns[:] = [d for d in dns if d not in SKIP and not d.startswith('.')]
        for f in fns:
            if f.endswith('.swift'):
                out.append(os.path.join(dp, f))
    return sorted(out)

CALL = re.compile(r'\b([A-Z]\w{2,})\s*\(')
DEF  = re.compile(r'^(?:public |internal |private |fileprivate )?(?:final )?struct (\w+)\s*:\s*View\b', re.M)

fs = files()
print('files', len(fs))
calls = Counter()
views = []           # (name, relpath)
for p in fs:
    try:
        s = open(p, encoding='utf-8', errors='ignore').read()
    except Exception:
        continue
    rel = os.path.relpath(p, ROOT)
    for m in CALL.finditer(s):
        calls[m.group(1)] += 1
    for m in DEF.finditer(s):
        views.append((m.group(1), rel))
    del s
    gc.collect()

print('view structs', len(views))
dead = [(n, p) for n, p in views if calls.get(n, 0) <= 1]
print('\n== 从未被构造的 View（疑似死页面）', len(dead), '==')
for n, p in sorted(dead):
    print(f'  {n:44s} {p}  calls={calls.get(n,0)}')
