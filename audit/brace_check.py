#!/usr/bin/env python3
"""检查 Swift 文件花括号/圆括号是否平衡（识别字符串、注释、插值）。"""
import sys

def check(path):
    s = open(path, encoding='utf-8').read()
    stack = []
    i = 0
    n = len(s)
    in_str = False
    esc = False
    line = 1
    # 处理多行字符串 """ 简化：按行扫描时遇到 """ 切换
    multi = False
    in_line_comment = False
    in_block_comment = False
    depth_comment = 0
    while i < n:
        c = s[i]
        if c == '\n':
            line += 1
            in_line_comment = False
        if in_line_comment:
            i += 1
            continue
        if in_block_comment:
            if c == '/' and i + 1 < n and s[i+1] == '*':
                depth_comment += 1
                i += 2
                continue
            if c == '*' and i + 1 < n and s[i+1] == '/':
                depth_comment -= 1
                if depth_comment == 0:
                    in_block_comment = False
                i += 2
                continue
            i += 1
            continue
        if in_str:
            if multi:
                if c == '"' and s[i:i+3] == '"""':
                    in_str = False
                    multi = False
                    i += 3
                    continue
                i += 1
                continue
            if esc:
                esc = False
            elif c == '\\':
                esc = True
            elif c == '"':
                in_str = False
            i += 1
            continue
        if c == '/' and i + 1 < n and s[i+1] == '/':
            in_line_comment = True
            i += 2
            continue
        if c == '/' and i + 1 < n and s[i+1] == '*':
            in_block_comment = True
            depth_comment = 1
            i += 2
            continue
        if c == '"':
            if s[i:i+3] == '"""':
                in_str = True
                multi = True
                i += 3
                continue
            in_str = True
            i += 1
            continue
        if c in '({[':
            stack.append((c, line))
        elif c in ')}]':
            pair = {'}': '{', ')': '(', ']': '['}[c]
            if not stack:
                return f'EXTRA {c} at line {line}'
            top, tl = stack.pop()
            if top != pair:
                return f'MISMATCH {top}@{tl} vs {c}@{line}'
        i += 1
    if in_str:
        return 'UNTERMINATED STRING'
    if stack:
        return f'UNCLOSED {stack[-1][0]} at line {stack[-1][1]} (depth {len(stack)})'
    return 'OK'

bad = 0
for p in sys.argv[1:]:
    r = check(p)
    if r != 'OK':
        bad += 1
        print(f'{p}: {r}')
print(f'checked {len(sys.argv)-1}, bad {bad}')
