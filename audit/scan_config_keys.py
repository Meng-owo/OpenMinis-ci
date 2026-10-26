#!/usr/bin/env python3
"""配置注册 vs 实际消费：抓 userDefaultsKey 和 AppStorage 的使用面。"""
import os, re, gc
from collections import Counter

ROOT = 'src/ios'
SKIP = {'MinisTests', 'MinisUITests', 'BridgeCore', 'iSH', 'NativeOffloads'}
REG = os.path.join(ROOT, 'Shared/Config/ConfigRegistry+Builtins.swift')

def files():
    for dp, dns, fns in os.walk(ROOT):
        dns[:] = [d for d in dns if d not in SKIP and not d.startswith('.')]
        for f in fns:
            if f.endswith('.swift'):
                yield os.path.join(dp, f)

reg = open(REG, encoding='utf-8', errors='ignore').read()
# path: "x.y",  ... userDefaultsKey: "z"
entries = []
for m in re.finditer(r'path:\s*"([\w.]+)"', reg):
    start = m.start()
    seg = reg[start:start+1200]
    uk = re.search(r'userDefaultsKey:\s*"([^"]+)"', seg)
    entries.append((m.group(1), uk.group(1) if uk else None))
print('registered', len(entries))

uses = Counter()
for p in files():
    if 'ConfigRegistry+Builtins' in p:
        continue
    try:
        s = open(p, encoding='utf-8', errors='ignore').read()
    except Exception:
        continue
    for path, uk in entries:
        if uk and ('"%s"' % uk) in s:
            uses[path] += 1
    del s
    gc.collect()

dead = [(p_, uk) for p_, uk in entries if uses[p_] == 0]
print('\n== 注册了但源码里没人读 UserDefaults 的键', len(dead), '==')
for p_, uk in dead:
    print(f'  {p_:40s} userDefaultsKey={uk}')
