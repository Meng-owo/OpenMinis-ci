#!/usr/bin/env python3
"""B28 E-1 第二步：把「中文当键、但表里只有英文键」的调用改成英文键。

只在 AppLocalized("…") 的键本身不在表里、而中文译文能反查到唯一英文键时才改。
不动括号，不做字符串整体重写 —— 只替换引号内的内容。
"""
import json
import re

CAT = json.load(open('src/ios/Localizable.xcstrings'))['strings']

REV = {}
for k, v in CAT.items():
    zh = v.get('localizations', {}).get('zh-Hans', {}).get('stringUnit', {}).get('value')
    if not zh:
        continue
    n = len(v.get('localizations', {}))
    if zh not in REV or n > REV[zh][1]:
        REV[zh] = (k, n)

FILES = [
    'src/ios/Views/Settings/AppearanceStudioView.swift',
    'src/ios/Shared/AppearanceStudio.swift',
    'src/ios/Shared/AppearanceThemePack.swift',
    'src/ios/Shared/AppearanceColorScale.swift',
    'src/ios/Shared/AppearanceThemeShuffle.swift',
]

# 只匹配 AppLocalized("键") 这一整段，整段替换，括号由我们控制。
CALL = re.compile(r'AppLocalized\("((?:[^"\\]|\\.)*)"\)')

total = 0
for path in FILES:
    src = open(path, encoding='utf-8').read()

    def repl(m):
        global total
        key = m.group(1)
        if key in CAT:
            return m.group(0)
        if key in REV:
            total += 1
            return 'AppLocalized("%s")' % REV[key][0]
        return m.group(0)

    out = CALL.sub(repl, src)
    if out != src:
        open(path, 'w', encoding='utf-8').write(out)
        print('%s: 改键' % path)
print('合计改键', total)
