#!/usr/bin/env python3
"""精确死组件检测：统计标识符出现次数（排除定义行、注释行）。"""
import os, re, gc, sys

ROOT = 'src/ios'
SKIP = {'MinisTests', 'MinisUITests', 'BridgeCore', 'iSH', 'NativeOffloads'}
NAMES = sys.argv[1:]

def files():
    for dp, dns, fns in os.walk(ROOT):
        dns[:] = [d for d in dns if d not in SKIP and not d.startswith('.')]
        for f in fns:
            if f.endswith('.swift'):
                yield os.path.join(dp, f)

for name in NAMES:
    pat = re.compile(r'\b' + re.escape(name) + r'\b')
    hits = []
    for p in files():
        try:
            s = open(p, encoding='utf-8', errors='ignore').read()
        except Exception:
            continue
        for i, line in enumerate(s.split('\n'), 1):
            if not pat.search(line):
                continue
            st = line.strip()
            if st.startswith('//') or st.startswith('///'):
                continue
            if re.match(r'^(public |private |internal |fileprivate )?(final )?(struct|class|enum|extension) ' + re.escape(name) + r'\b', st):
                hits.append((os.path.relpath(p, ROOT), i, 'DEF'))
                continue
            hits.append((os.path.relpath(p, ROOT), i, st[:90]))
        del s
        gc.collect()
    print(f'== {name}: {len(hits)}')
    for h in hits[:8]:
        print('   ', h)
