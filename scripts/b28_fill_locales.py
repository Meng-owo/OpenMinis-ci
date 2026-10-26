#!/usr/bin/env python3
"""给 xcstrings 里**已存在**的条目补语种。

`scripts/add_localization.py` 是纯插入器：键已存在就跳过，不碰它。
但有些键在基线里就只有 en + zh-Hans 两种语种（本轮遇到的 8 条设置页
图标标题），本轮已经把调用点改成走 AppLocalized 了，这些键的其它 7 个
语种就成了「查得到、但显示英文」。

这个脚本只往已存在的条目里**加**语种，不改、不删任何已有语种的值，
也不新增键。改完同样要字节级可验证：把新增的语种块删掉，剩下的内容
与改之前逐字节相同。

用法：
    scripts/b28_fill_locales.py <input.json> [--dry-run]

input 是 {key: {locale: value}}。key 必须已经存在于目录里。
"""
import argparse
import json
import pathlib
import re
import sys

REPO = pathlib.Path(__file__).resolve().parent.parent
CATALOG = REPO / 'src/ios/Localizable.xcstrings'
LOCALES = ['de', 'en', 'es', 'fr', 'ja', 'ko', 'ru', 'zh-Hans', 'zh-Hant']

# 一个条目在目录里的样子：
#     "key" : {
#       "extractionState" : "manual",
#       "localizations" : {
#         "en" : {
#           "stringUnit" : { ... }
#         }
#       }
#     },
#
# 用行级扫描定位，不用跨行正则 —— 跨行正则在这个格式上会漏掉大量条目
# （有的条目没有 extractionState，缩进和闭合都有差异），一旦漏了，
# 后面按 offset 插入就会错位，把文件写坏。
KEY_LINE = re.compile(r'^    "((?:[^"\\]|\\.)*)"\s*:\s*\{$')
LOC_OPEN = re.compile(r'^      "localizations"\s*:\s*\{$')


def parse_entries(text):
    """返回 {key: (start, end)}，区间是该条目从 `    "key" : {` 到它的
    闭括号 `    }`（含）之间的字符范围。"""
    lines = text.split('\n')
    starts = []
    for i, line in enumerate(lines):
        m = KEY_LINE.match(line)
        if m:
            starts.append((i, json.loads('"%s"' % m.group(1))))
    out = {}
    for idx, (i, key) in enumerate(starts):
        # 条目的闭括号是下一个缩进为 4 的 `}` 之前的那个
        end = None
        for j in range(i + 1, len(lines)):
            if lines[j].rstrip() in ('    },', '    }'):
                end = j
                break
        if end is None:
            continue
        out[key] = (i, end)
    return out, lines


def find_localizations_block(lines, start, end):
    """在条目的行区间里找 localizations 块，返回 (open_line, inner_start,
    inner_end)。inner_start..inner_end 是各语种条目的行范围（不含
    localizations 自己的闭括号）。"""
    open_at = None
    for j in range(start, end):
        if LOC_OPEN.match(lines[j]):
            open_at = j
            break
    if open_at is None:
        return None
    # localizations 的闭括号：缩进 6 的 `}`
    close_at = None
    for j in range(open_at + 1, end + 1):
        if j < len(lines) and lines[j].rstrip() in ('      },', '      }'):
            close_at = j
            break
    if close_at is None:
        return None
    return open_at, open_at + 1, close_at


def esc(s: str) -> str:
    return s.replace('\\', '\\\\').replace('"', '\\"')


def render_locale(locale: str, value: str) -> str:
    return ('        "%s" : {\n'
            '          "stringUnit" : {\n'
            '            "state" : "translated",\n'
            '            "value" : "%s"\n'
            '          }\n'
            '        },\n') % (locale, esc(value))


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument('input')
    ap.add_argument('--dry-run', action='store_true')
    args = ap.parse_args()

    wanted = json.load(open(args.input, encoding='utf-8'))
    original = CATALOG.read_text(encoding="utf-8")
    before = json.loads(original)['strings']

    unknown = [k for k in wanted if k not in before]
    if unknown:
        sys.exit('these keys are not in the catalog: %s' % unknown[:5])

    # 每个键要补哪些语种
    plan = {}
    for k, locs in wanted.items():
        have = set(before[k].get('localizations', {}))
        todo = {lc: v for lc, v in locs.items() if lc not in have}
        if todo:
            plan[k] = todo
        for lc in todo:
            if lc not in LOCALES:
                sys.exit('unknown locale %r for key %r' % (lc, k))

    if not plan:
        print('\nnothing to do — every requested locale is already present.')
        return 0

    for k, todo in sorted(plan.items()):
        print('  + fill [%s]: %s' % (','.join(sorted(todo)), k[:60]))

    if args.dry_run:
        print('\n--dry-run: no changes written.')
        return 0

    # 先在内存里拼，再校验，**然后**才落盘。写盘先于校验的话，校验失败
    # 时异常在回滚之前抛出，坏文件就留在磁盘上了。
    entries, lines = parse_entries(original)
    missing_entries = [k for k in plan if k not in entries]
    if missing_entries:
        sys.exit('could not locate entries for: %s' % missing_entries[:5])

    inserts = []
    for k, todo in plan.items():
        start, end = entries[k]
        block = find_localizations_block(lines, start, end)
        if not block:
            sys.exit('could not find the localizations block for key %r' % k)
        open_at, inner_start, inner_end = block
        # 最后一条语种的闭括号行（缩进 8 的 `}`），它是 localizations 块里
        # 最后一个条目，末尾**没有**逗号。直接往后接新语种会写成
        # `        }\n        "de" : {` —— JSON 非法，所以先给它补逗号。
        last_line = inner_end - 1
        if lines[last_line].rstrip() != '        }':
            sys.exit('unexpected last locale line for key %r: %r' % (k, lines[last_line]))
        added_lines = []
        for lc in sorted(todo):
            added_lines.extend(render_locale(lc, todo[lc]).rstrip('\n').split('\n'))
        # render_locale 每块都自带尾逗号（它是为"后面还有条目"设计的）。这里
        # 插入的位置后面紧跟 localizations 的闭括号，所以最后一块不能有逗号。
        if added_lines:
            added_lines[-1] = added_lines[-1].rstrip()
            if added_lines[-1].endswith(','):
                added_lines[-1] = added_lines[-1][:-1]
        # 只替换这一个条目自己的行段 —— 从 start 切，不是从文件头切。
        # （写 lines[:last_line] 会把整个文件从第 0 行复制进来。）
        new_lines = (lines[start:last_line]
                     + ['        },']
                     + added_lines
                     + lines[last_line + 1:end])
        # end 就是条目闭括号所在的那一行，替换范围是 [start, end]（含）。
        # 写成 end + 1 会多吃掉下一条目的首行，把文件写坏。
        inserts.append((start, end, new_lines))

    for start, end, new_lines in sorted(inserts, key=lambda t: -t[0]):
        lines[start:end] = new_lines
    text = '\n'.join(lines)

    try:
        after = json.loads(text)['strings']
    except Exception as e:
        sys.exit('FAILED: result is not valid JSON (%s). Nothing written.' % e)

    problems = []
    for k, v in before.items():
        if k not in after:
            problems.append('key LOST: %r' % k)
            continue
        for lc, val in v.get('localizations', {}).items():
            got = after[k].get('localizations', {}).get(lc)
            if got != val:
                problems.append('existing locale CHANGED: %r/%s' % (k, lc))
    for k, todo in plan.items():
        for lc, val in todo.items():
            got = after[k].get('localizations', {}).get(lc, {}).get('stringUnit', {}).get('value')
            if got != val:
                problems.append('not filled: %r/%s' % (k, lc))
    if problems:
        sys.exit('FAILED, nothing written:\n  ' + '\n  '.join(problems[:10]))

    # 必须显式 utf-8：iSH 上 locale.getpreferred(encoding) 不保证是 UTF-8，
    # 用默认编码写中文会花屏。
    CATALOG.write_text(text, encoding='utf-8')

    print('\n✅ filled %d key(s), no existing value touched' % len(plan))
    return 0


if __name__ == '__main__':
    sys.exit(main())
