#!/usr/bin/env python3
"""配置项真实性：区分 reader/writer 闭包（活的）与 userDefaultsKey（要另查）。"""
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
entries = []
for m in re.finditer(r'path:\s*"([\w.]+)"', reg):
    seg = reg[m.start():m.start()+1400]
    uk = re.search(r'userDefaultsKey:\s*"([^"]+)"', seg)
    has_reader = re.search(r'reader:\s*\{', seg) is not None
    entries.append((m.group(1), uk.group(1) if uk else None, has_reader))

need = [(p_, uk) for p_, uk, r in entries if uk and not r]
print('注册项', len(entries), '／需要另查 UserDefaults 的', len(need))

uses = Counter()
for p in files():
    if 'ConfigRegistry+Builtins' in p:
        continue
    try:
        s = open(p, encoding='utf-8', errors='ignore').read()
    except Exception:
        continue
    for p_, uk in need:
        if '"%s"' % uk in s:
            uses[p_] += 1
    del s
    gc.collect()

dead = [(p_, uk) for p_, uk in need if uses[p_] == 0]
print('\n== 声明了 UserDefaults 键但没人读', len(dead))
for p_, uk in dead:
    print(f'  {p_:38s} {uk}')
