#!/usr/bin/env python3
"""通知对称性：发的地方 vs 收的地方（两种写法都认）。"""
import os, re, gc
from collections import defaultdict

ROOT = 'src/ios'
SKIP = {'MinisTests', 'MinisUITests', 'BridgeCore', 'iSH', 'NativeOffloads'}

def files():
    for dp, dns, fns in os.walk(ROOT):
        dns[:] = [d for d in dns if d not in SKIP and not d.startswith('.')]
        for f in fns:
            if f.endswith('.swift'):
                yield os.path.join(dp, f)

post = defaultdict(set)
recv = defaultdict(set)
POST = [re.compile(r'post\(\s*name:\s*\.(\w+)'), re.compile(r'post\(\s*name:\s*Notification\.Name\("([^"]+)"\)')]
RECV = [re.compile(r'publisher\(for:\s*\.(\w+)'), re.compile(r'forName:\s*\.(\w+)'),
        re.compile(r'addObserver\([^)]*?name:\s*\.(\w+)'), re.compile(r'onReceive\(\s*\.(\w+)')]

for p in files():
    try:
        s = open(p, encoding='utf-8', errors='ignore').read()
    except Exception:
        continue
    rel = os.path.relpath(p, ROOT)
    for rx in POST:
        for m in rx.finditer(s):
            post[m.group(1)].add(rel)
    for rx in RECV:
        for m in rx.finditer(s):
            recv[m.group(1)].add(rel)
    del s
    gc.collect()

dead_post = sorted(set(post) - set(recv))
dead_recv = sorted(set(recv) - set(post))
print('== 发了没人收', len(dead_post))
for k in dead_post:
    print(f'  {k:38s} {sorted(post[k])[:2]}')
print('\n== 收了没人发', len(dead_recv))
for k in dead_recv:
    print(f'  {k:38s} {sorted(recv[k])[:2]}')
