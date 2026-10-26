#!/usr/bin/env python3
"""B28 E-1: 把 Shared 层的中文枚举标题改成 AppLocalized，并把缺的键补进 xcstrings。

只改 `case .x: return "中文"` 这一种形态（已用脚本确认全部是这一种）。
"""
import json
import re
import sys

FILES = [
    'src/ios/Shared/AppearanceStudio.swift',
    'src/ios/Shared/AppearanceThemePack.swift',
    'src/ios/Shared/AppearanceColorScale.swift',
    'src/ios/Shared/AppearanceThemeShuffle.swift',
]

CASE_RE = re.compile(r'^(\s*)(case [^:]+:) return "([^"]*[\u4e00-\u9fff][^"]*)"$')

changed = {}
for path in FILES:
    lines = open(path, encoding='utf-8').read().split('\n')
    out = []
    n = 0
    for line in lines:
        m = CASE_RE.match(line)
        if m:
            indent, label, text = m.group(1), m.group(2), m.group(3)
            out.append('%s%s return AppLocalized("%s")' % (indent, label, text))
            n += 1
        else:
            out.append(line)
    if n:
        open(path, 'w', encoding='utf-8').write('\n'.join(out))
        changed[path] = n

for p, n in changed.items():
    print('%s: %d 条' % (p, n))
print('合计', sum(changed.values()))
