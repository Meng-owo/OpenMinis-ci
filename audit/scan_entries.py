#!/usr/bin/env python3
"""入口体检：找点了没反应的按钮、只写不读/只读不写的开关、发出去没人收的通知。"""
import os, re, sys, json, gc

ROOT = 'src/ios'
SKIP_DIRS = {'MinisTests', 'MinisUITests', 'BridgeCore', 'iSH', 'NativeOffloads'}

def swift_files():
    out = []
    for dp, dns, fns in os.walk(ROOT):
        dns[:] = [d for d in dns if d not in SKIP_DIRS and not d.startswith('.')]
        for f in fns:
            if f.endswith('.swift'):
                out.append(os.path.join(dp, f))
    return out

def read(p):
    try:
        return open(p, encoding='utf-8', errors='ignore').read()
    except Exception:
        return ''

files = swift_files()
print('files', len(files))

defaults_read = {}
defaults_write = {}
notif_post = {}
notif_observe = {}
empty_buttons = []
dead_toggles = []

BUTTON_EMPTY = re.compile(r'Button\s*(?:\([^)]*\))?\s*\{\s*\}\s*(?:label\s*:|\{)', re.M)
BUTTON_ACTION_EMPTY = re.compile(r'Button\s*\{\s*\}\s*label\s*:\s*\{', re.M)
TOGGLE = re.compile(r'Toggle\s*\(([^)]*)\)')

for p in files:
    s = read(p)
    if not s:
        continue
    rel = os.path.relpath(p, ROOT)
    for m in BUTTON_EMPTY.finditer(s):
        ln = s[:m.start()].count('\n') + 1
        empty_buttons.append((rel, ln, s[m.start():m.start()+60].replace('\n', ' ')))
    for m in BUTTON_ACTION_EMPTY.finditer(s):
        ln = s[:m.start()].count('\n') + 1
        empty_buttons.append((rel, ln, s[m.start():m.start()+60].replace('\n', ' ')))
    for m in re.finditer(r'UserDefaults\.standard\.(?:bool|object|string|integer|double|data)\(forKey:\s*"([^"]+)"', s):
        defaults_read.setdefault(m.group(1), set()).add(rel)
    for m in re.finditer(r'UserDefaults\.standard\.set\([^,]+,\s*forKey:\s*"([^"]+)"', s):
        defaults_write.setdefault(m.group(1), set()).add(rel)
    for m in re.finditer(r'@AppStorage\(\s*"([^"]+)"', s):
        defaults_read.setdefault(m.group(1), set()).add(rel)
        defaults_write.setdefault(m.group(1), set()).add(rel)
    for m in re.finditer(r'@AppStorage\(([\w.]+)\.', s):
        pass
    for m in re.finditer(r'NotificationCenter\.default\.post\(\s*name:\s*\.(\w+)', s):
        notif_post.setdefault(m.group(1), set()).add(rel)
    for m in re.finditer(r'NotificationCenter\.default\.post\(\s*name:\s*Notification\.Name\("([^"]+)"\)', s):
        notif_post.setdefault(m.group(1), set()).add(rel)
    for m in re.finditer(r'onReceive\(\s*\.(\w+)', s):
        notif_observe.setdefault(m.group(1), set()).add(rel)
    for m in re.finditer(r'addObserver\([^)]*name:\s*\.(\w+)', s):
        notif_observe.setdefault(m.group(1), set()).add(rel)
    for m in re.finditer(r'addObserver\([^)]*name:\s*Notification\.Name\("([^"]+)"\)', s):
        notif_observe.setdefault(m.group(1), set()).add(rel)
    gc.collect()

print('\n== 空按钮 ==')
for r in empty_buttons[:80]:
    print(r[0], r[1], r[2][:60])

wo = sorted(set(defaults_write) - set(defaults_read))
ro = sorted(set(defaults_read) - set(defaults_write))
print('\n== 只写不读的键', len(wo), '==')
for k in wo[:60]:
    print(' ', k, sorted(defaults_write[k])[:2])
print('\n== 只读不写的键', len(ro), '==')
for k in ro[:60]:
    print(' ', k, sorted(defaults_read[k])[:2])

po = sorted(set(notif_post) - set(notif_observe))
oo = sorted(set(notif_observe) - set(notif_post))
print('\n== 发了没人收', len(po), '==')
for k in po[:40]:
    print(' ', k, sorted(notif_post[k])[:2])
print('\n== 有人收但没人发', len(oo), '==')
for k in oo[:40]:
    print(' ', k, sorted(notif_observe[k])[:2])
