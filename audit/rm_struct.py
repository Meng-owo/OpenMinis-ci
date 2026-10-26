#!/usr/bin/env python3
"""按结构体名删除整块（花括号配对），保留其余内容。"""
import re, sys, io

def strip_braces_lines(text, start_idx):
    """从 start_idx（'{' 位置）开始找配对结束，返回结束后的索引。"""
    depth = 0
    i = start_idx
    in_str = False
    in_line = False
    in_block = False
    esc = False
    n = len(text)
    while i < n:
        c = text[i]
        if in_line:
            if c == '\n':
                in_line = False
            i += 1
            continue
        if in_block:
            if c == '*' and i + 1 < n and text[i+1] == '/':
                in_block = False
                i += 2
                continue
            i += 1
            continue
        if in_str:
            if esc:
                esc = False
            elif c == '\\':
                esc = True
            elif c == '"':
                in_str = False
            i += 1
            continue
        if c == '/' and i + 1 < n and text[i+1] == '/':
            in_line = True
            i += 2
            continue
        if c == '/' and i + 1 < n and text[i+1] == '*':
            in_block = True
            i += 2
            continue
        if c == '"':
            in_str = True
            i += 1
            continue
        if c == '{':
            depth += 1
        elif c == '}':
            depth -= 1
            if depth == 0:
                return i + 1
        i += 1
    return -1

def remove_struct(path, name):
    src = open(path, encoding='utf-8').read()
    pat = re.compile(r'^[ \t]*(?:private |fileprivate |internal |public )?struct ' + re.escape(name) + r'\b', re.M)
    m = pat.search(src)
    if not m:
        return 'MISS'
    # 从声明行开始，找第一个 '{'
    brace = src.find('{', m.start())
    if brace < 0:
        return 'NOBRACE'
    end = strip_braces_lines(src, brace)
    if end < 0:
        return 'UNBALANCED'
    # 往前吃掉紧邻的 /// 注释行和空行
    start = m.start()
    lines = src[:start].split('\n')
    while lines and (lines[-1].strip().startswith('///') or lines[-1].strip().startswith('//')):
        lines.pop()
    while lines and lines[-1].strip() == '':
        lines.pop()
    head = '\n'.join(lines)
    if head:
        head += '\n\n'
    tail = src[end:]
    # 去掉尾部多余空行
    tail = re.sub(r'^\n+', '\n', tail)
    open(path, 'w', encoding='utf-8').write(head + tail)
    return 'OK'

if __name__ == '__main__':
    for arg in sys.argv[1:]:
        path, name = arg.split('|')
        print(name, remove_struct(path, name))
