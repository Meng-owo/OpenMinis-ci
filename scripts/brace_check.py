import sys, io

def scan(path):
    t = io.open(path, encoding='utf-8', errors='replace').read()
    # crude but effective: strip line comments, block comments, and string
    # literals (incl. triple-quoted) before counting braces.
    out = []
    i, n = 0, len(t)
    while i < n:
        c = t[i]
        if c == '/' and i+1 < n and t[i+1] == '/':
            while i < n and t[i] != '\n':
                i += 1
            continue
        if c == '/' and i+1 < n and t[i+1] == '*':
            i += 2
            while i+1 < n and not (t[i] == '*' and t[i+1] == '/'):
                i += 1
            i += 2
            continue
        if c == '#':
            m = 0
            j = i
            while j < n and t[j] == '#':
                m += 1
                j += 1
            if j < n and t[j] == '"' and m > 0:
                close = '"' + '#' * m
                body = t[j+1:]
                k = body.find(close)
                if k != -1:
                    i = j + 1 + k + len(close)
                    continue
        if c == '"':
            if t[i:i+3] == '"""':
                i += 3
                while i+1 < n and t[i:i+3] != '"""':
                    if t[i] == '\\':
                        i += 1
                    i += 1
                i += 3
                continue
            i += 1
            while i < n and t[i] != '"':
                if t[i] == '\\':
                    i += 1
                if t[i] == '\n':
                    break
                i += 1
            i += 1
            continue
        if c == '#' and t[i:i+4] == '#if ':
            out.append(c)
        out.append(c)
        i += 1
    s = ''.join(out)
    stack = []
    pairs = {')': '(', ']': '[', '}': '{'}
    line = 1
    for ch in s:
        if ch == '\n':
            line += 1
        elif ch in '([{':
            stack.append((ch, line))
        elif ch in ')]}':
            if not stack:
                return f"{path}: UNMATCHED close {ch} near line {line}"
            o, ol = stack.pop()
            if o != pairs[ch]:
                return f"{path}: MISMATCH {o}@{ol} vs {ch}@{line}"
    if stack:
        o, ol = stack[-1]
        return f"{path}: UNCLOSED {o} at line {ol}"
    return f"{path}: OK"

for p in sys.argv[1:]:
    print(scan(p))
