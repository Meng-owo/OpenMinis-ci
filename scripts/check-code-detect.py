import re

KW = ["def ","class ","func ","function ","import ","from ","package ","namespace ",
      "public ","private ","protected ","static ","const ","let ","var ","return ",
      "if ","else","elif ","for ","while ","switch ","case ","try ","catch ","finally ",
      "throw ","async ","await ","yield ","struct ","enum ","impl ","fn ","pub ","use ",
      "export ","default ","#include","#define","#!/","<?php","SELECT ","INSERT ",
      "UPDATE ","DELETE ","CREATE ","interface ","type ","module ","require(","echo ",
      "FROM ","WHERE ","GROUP ","ORDER ","JOIN ","VALUES ","SET ","INSERT INTO ",
      "except ","raise ","with open(","while True"]

CMDS = ("git","docker","docker-compose","npm","npx","yarn","pnpm","pip","pip3","curl","wget",
        "cd ","ls ","sudo","apt","apt-get","brew","make ","python","python3","node ","go ","cargo",
        "kubectl","ssh ","scp ","tar ","unzip","chmod","cat ","grep","sed ","awk ","find ","mkdir",
        "rm ","cp ","mv ","systemctl","service ","nohup","export ","set -","source ","bash ","sh ")

CJK = lambda ch: 0x4e00 <= ord(ch) <= 0x9fff

def cjk_ratio(s):
    if not s: return 0.0
    n = sum(1 for c in s if CJK(c))
    return n / len(s)

def line_score(raw):
    t = raw.strip()
    if not t: return -99
    s = 0
    if raw.startswith("\t") or raw.startswith("  "): s += 2
    if t.endswith("{") or t.endswith("}"): s += 2
    if t.endswith(";"): s += 1
    if any(t.startswith(k) for k in KW): s += 2
    if t.startswith("#!"): s += 3
    if re.match(r'^</?[a-zA-Z][^>]*>$', t): s += 3
    if t.endswith("\\"): s += 3
    if re.match(r'^(try|else|finally|do|begin):$', t): s += 2
    if any(t.startswith(c) for c in CMDS): s += 2
    if t.startswith("//") or t.startswith("#") or t.startswith("/*") or t.startswith("* ") or t.startswith("--"): s += 1
    if any(x in t for x in ("=>","->","::","==","!=","&&","||","+=","-=",":=","<>")): s += 1
    if re.match(r'^[A-Za-z_$][\w$.\[\]]*\s*=\s*\S', t): s += 1
    if re.match(r'^[A-Za-z_$][\w$.]*\s*\(.*\)\s*[;{]?$', t): s += 1
    punct = sum(1 for c in t if c in "{}();=<>[]$")
    if punct / len(t) >= 0.10: s += 1
    if cjk_ratio(t) > 0.15: s -= 3
    if t[-1] in "。！？，、；：": s -= 3
    return s

def is_comment(raw):
    t = raw.strip()
    return t.startswith("//") or t.startswith("/*") or t.startswith("* ") \
        or t.startswith("--") or t.startswith("<!--")

def is_list_line(raw):
    t = raw.strip()
    if t.startswith(("- ", "* ", "+ ", "> ", "# ")):
        return True
    return re.match(r'^\d+\.\s', t) is not None

def has_fence(s):
    return "```" in s or "~~~" in s

def looks_like_json(s):
    t = s.strip()
    if not (t.startswith("{") or t.startswith("[")):
        return False
    try:
        import json
        json.loads(t)
        return True
    except Exception:
        return False

def looks_like_diff(lines):
    body = [l for l in lines if l.strip()]
    if len(body) < 2:
        return False
    has_header = any(l.startswith(("@@", "diff --git", "+++", "---")) for l in body)
    if not has_header:
        return False
    diff = sum(1 for l in body if l.startswith(("@@", "+++", "---", "diff --git", "+", "-")))
    return diff >= max(2, len(body) * 3 // 5) and cjk_ratio("".join(body)) < 0.05

def looks_like_indented(lines):
    body = [l for l in lines if l.strip()]
    if len(body) < 2:
        return False
    indented = sum(1 for l in body if l.startswith("\t") or l.startswith("    "))
    codeish = sum(1 for l in body if line_score(l) >= 1)
    listish = sum(1 for l in body if is_list_line(l))
    return (indented >= max(2, len(body) * 4 // 5)
            and codeish >= max(1, len(body) // 2)
            and listish == 0
            and cjk_ratio("".join(body)) < 0.15)

def looks_like_single_line(raw):
    t = raw.strip()
    if not t or "\n" in t:
        return False
    if cjk_ratio(t) > 0.05:
        return False
    if t[-1] in ".。！？!?":
        return False
    if line_score(t) >= 3:
        return True
    code_punct = any(x in t for x in ("(", "{", "=", ";", "[", "::", "->", "=>"))
    if code_punct and line_score(t) >= 2:
        return True
    if t.startswith("SELECT ") and " FROM " in t:
        return True
    if t.startswith(("INSERT INTO ", "UPDATE ", "DELETE FROM ")):
        return True
    return any(t.startswith(c) for c in CMDS) and line_score(t) >= 2

def is_code_run(run):
    # 注释行不参与投票：代码里的中文注释是常态，不该把整段判成散文。
    body = [l for l in run if not is_comment(l)]
    if not body:
        return False
    if sum(1 for l in body if is_list_line(l)) >= max(1, len(body) // 2):
        return False
    joined = "\n".join(body)
    if looks_like_json(joined):
        return True
    if looks_like_diff(body):
        return True
    if looks_like_indented(body):
        return True
    if len(body) == 1:
        return looks_like_single_line(body[0])
    scores = [line_score(l) for l in body]
    if len(body) == 2:
        return all(x >= 2 for x in scores) and cjk_ratio(joined) < 0.05
    strong = sum(1 for x in scores if x >= 2)
    ratio = strong / len(body)
    if len(body) >= 4:
        if ratio < 0.6:
            return False
    elif ratio < 0.8:
        return False
    if cjk_ratio(joined) > 0.10:
        return False
    if sum(1 for x in scores if x >= 3) < 2 and not all(x >= 2 for x in scores):
        return False
    return True

def auto_fence(text):
    if has_fence(text):
        return text
    lines = text.split("\n")
    if not lines:
        return text
    if looks_like_json(text) or looks_like_diff(lines) or looks_like_indented(lines):
        return "```\n" + text + "\n```"
    out, run = [], []
    def flush():
        if not run: return
        if is_code_run(run):
            out.append("```"); out.extend(run); out.append("```")
        else:
            out.extend(run)
        run.clear()
    for idx, line in enumerate(lines):
        nxt = lines[idx + 1] if idx + 1 < len(lines) else ""
        if not line.strip():
            flush(); out.append(line)
        elif line_score(line) >= 1 or (run and is_comment(line)) \
                or (is_comment(line) and line_score(nxt) >= 2):
            run.append(line)
        else:
            flush(); out.append(line)
    flush()
    return "\n".join(out)

CODE = [
"""def foo(x):
    return x * 2""",
"""const a = 1;
const b = 2;
console.log(a + b);""",
"""import os
from pathlib import Path

for p in Path('.').iterdir():
    print(p)""",
"""SELECT id, name
FROM users
WHERE age > 18;""",
"""func handle() {
    guard let x = y else { return }
    print(x)
}""",
"""curl -X POST https://api.example.com/v1 \\
  -H "Content-Type: application/json" \\
  -d '{"a":1}'""",
"""{
  "name": "test",
  "value": 123
}""",
"""if (a == b) {
  doSomething();
}""",
"""class Foo:
    def __init__(self):
        self.x = 1""",
"""let arr = [1, 2, 3]
let sum = arr.reduce(0, +)""",
"""<div class="box">
  <span>hi</span>
</div>""",
"""#!/bin/bash
set -e
echo "start\"""",
"""fn main() {
    let x = 5;
    println!("{}", x);
}""",
"""public class User {
    private String name;
}""",
"""try:
    x = int(s)
except ValueError:
    x = 0""",
"""for i in range(10):
    print(i)""",
"""export default function App() {
  return null;
}""",
"""const res = await fetch(url, {
  method: 'POST'
});""",
"""x = y + 1
z = x * 2""",
"""git commit -m "fix: crash"
git push origin main""",
"""struct Point {
    var x: Double
    var y: Double
}""",
"""async function load() {
  const r = await fetch('/a');
  return r.json();
}""",
"""int main(void) {
    printf("hello\\n");
    return 0;
}""",
"""CREATE TABLE t (
  id INTEGER PRIMARY KEY,
  name TEXT
);""",
"""print("hello")
print("world")""",
"""docker run -d -p 8080:80 nginx
docker ps""",
"""type Props = {
  title: string;
};""",
"""#include <stdio.h>
int main() { return 0; }""",
"""var data = JSON.parse(str);
if (data.ok) { render(data); }""",
"""def f(a, b=2, *args):
    return a + b""",
"""// 这里要判断一下
if (x == 1) {
    doIt();
}""",
"""# 这是 python 注释
def f():
    return 1""",
"""npm install""",
"""git status""",
"""{"a": 1, "b": [2, 3]}""",
"""~~~swift
let x = 1
let y = 2
~~~""",
"""diff --git a/a.swift b/a.swift
@@ -1 +1 @@
-let x = 1
+let x = 2""",
"""    let x = 1
    let y = 2""",
"""print("hi")""",
"""SELECT * FROM users""",
]

PROSE = [
"""今天我想问一下那个东西到底是怎么算的，你帮我看看。""",
"""我昨天试了三次都不行，第三次直接卡住了。""",
"""这个方案我看了，感觉不太对，能不能换一个思路？""",
"""第一，先把数据库备份；第二，再改配置；第三，重启服务。""",
"""你说的那个 x = 5 是什么意思，我没看懂。""",
"""我记得之前你说过，return 这个词在这里不是返回值的意思。""",
"""for 这个介词在英文里有很多用法，比如 for example。""",
"""我想让这个 app 更好看一点，颜色再暖一些，别那么冷。""",
"""这里有个问题：打开会话的时候会闪退，只有一个会话这样。""",
"""能不能帮我把这两句话合并成一句，短一点。""",
"""今天天气不错，出去走走吧。""",
"""我不喜欢这个字体，太硬了，换一个圆一点的。""",
"""把这段代码复制到左边，然后把右边删掉。""",
"""好的，我知道了，你先忙你的。""",
"""这个功能是不是可以做成可折叠的？长文太占地方了。""",
"""The quick brown fox jumps over the lazy dog. It was a dark night.""",
"""I think we should try a different approach here, because the current one is slow.""",
"""Please return the file to me when you are done with it.""",
"""For example, we could split this into two steps and check each one.""",
"""Let me know if you need anything else from my side.""",
"""This is a long sentence that describes what happened yesterday in detail.""",
"""Can you explain why the value is 5 and not 6?""",
"""He said that the import of that module was not necessary.""",
"""We need to wait for the build to finish before we ship it.""",
"""The class was cancelled because the teacher was ill.""",
"""I would like a coffee, please, with a little milk.""",
"""关于那个崩溃，我装上新包之后还是会出现，不是每次都出现。""",
"""你上次说的那个办法，我试了，没有用。""",
"""这个气泡展开之后收不回去，点收起没反应。""",
"""代码块里面那些行号我不想要，看着乱。""",
"""我们要把它做成一个整体，不要各管各的。""",
"""先别急着改，你把原因查清楚再告诉我。""",
"""I went home; it was late;
She stayed behind; it rained;
We slept; the morning came;""",
"""1. 先备份数据库
2. 再改配置
3. 最后重启服务""",
"""- 第一项：备份
- 第二项：改配置
- 第三项：重启""",
"""发邮件给 me@example.com，说明情况。
附件放在 /tmp/report.pdf 里。
时间是明天下午三点。""",
"""网址是 https://example.com/a?b=1
打开之后点右上角的按钮
然后选第二个选项""",
"""引用一句他说的话：
“先做完再说话。”
我觉得有道理。""",
"""这个接口返回的是 {"ok": true} 这种格式，你要注意一下。
另外字段名可能变了。""",
"""第一步：打开设置
第二步：找到外观
第三步：点进去""",
"""He said: "do it now; don't wait."
Then he left the room;
We never saw him again.""",
"""价格是 5 * 3 = 15 块。
数量按 2 个算。
一共 30 块。""",
"""备注：这里要加一个 try 保护，别让异常冒出来。
还有记得写日志。""",
"""I think we should try a different approach here, because the current one is slow.""",
"""Please return the file to me when you are done with it.""",
"""   这是缩进的普通说明
   第二行也是说明""",
"""    - item one
    - item two""",
"""- item one
- item two""",
"""    1. first
    2. second""",
"""Please select the best option from the list.""",
]

if __name__ == "__main__":
    fp = [p for p in PROSE if not has_fence(p) and auto_fence(p) != p]
    fn = [c for c in CODE if not (has_fence(c) or auto_fence(c) != c)]
    print("误报", len(fp), "漏判", len(fn), "/", len(CODE))
    for x in fp: print("FP:", x[:50])
    for x in fn: print("FN:", x[:50])
