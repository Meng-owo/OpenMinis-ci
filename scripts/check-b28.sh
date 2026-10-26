#!/bin/sh
# B28 外观与主题 —— 每条修复的可执行断言。
#
# 用法：sh scripts/check-b28.sh [条目编号...]
#   不带参数 = 全跑；带参数 = 只跑那几条（例如 `sh scripts/check-b28.sh B-1 E-2`）。
#
# 规矩：每条断言都必须在修之前是红的。红的证据在回执里，不在这个文件里。

set -u
cd "$(dirname "$0")/.." || exit 1

FAIL=0
WANT="${*:-}"
ITEM_FAIL=0

want() {
    [ -z "$WANT" ] && return 0
    for w in $WANT; do [ "$w" = "$1" ] && return 0; done
    return 1
}
bad()  { echo "FAIL $1: $2"; ITEM_FAIL=1; FAIL=1; }
begin(){ ITEM_FAIL=0; }
end()  { [ "$ITEM_FAIL" -eq 0 ] && echo "OK   $1"; }

# ---------------------------------------------------------------- B-1 字距
if want B-1; then
    begin
    f=src/ios/Views/Chat/SelectableMarkdownView.swift
    grep -q 'storedLetterSpacing()' "$f" || bad B-1 'storedLetterSpacing 没人调用'
    grep -q '\.kern' "$f" || bad B-1 '没有 kern 应用'
    end B-1
fi

# ------------------------------------------------------- B-3 thinking 三色
if want B-3; then
    begin
    f=src/ios/Shared/AppearanceThemePack.swift
    python3 - "$f" <<'EOF' || { ITEM_FAIL=1; FAIL=1; }
import re, sys
src = open(sys.argv[1], encoding='utf-8').read()
m = re.search(r'enum MinisThemeShape \{(.*?)\n\}', src, re.S)
if not m:
    print('FAIL B-3: 找不到 MinisThemeShape')
    sys.exit(1)
block = m.group(1)
for prop, field in [('thinkingFill', 'thinkingFillHex'),
                    ('thinkingStroke', 'thinkingStrokeHex'),
                    ('thinkingAccent', 'thinkingAccentHex')]:
    pm = re.search(r'static var %s: Color \{(.*?)\n    \}' % prop, block, re.S)
    if not pm:
        print('FAIL B-3: %s 不存在' % prop)
        sys.exit(1)
    body = pm.group(1)
    if 'pack.' + field not in body:
        print('FAIL B-3: %s 没读 pack.%s' % (prop, field))
        sys.exit(1)
    if 'isEmpty' not in body:
        print('FAIL B-3: %s 空串没回落到 accent' % prop)
        sys.exit(1)
EOF
    end B-3
fi

# ------------------------------------------------------------- E-1 本地化
if want E-1; then
    begin
    python3 - <<'EOF' || { ITEM_FAIL=1; FAIL=1; }
import json, re, sys
cat = json.load(open('src/ios/Localizable.xcstrings'))['strings']
bad = 0
targets = [
    'src/ios/Views/Settings/AppearanceStudioView.swift',
    'src/ios/Shared/AppearanceStudio.swift',
    'src/ios/Shared/AppearanceThemePack.swift',
    'src/ios/Shared/AppearanceColorScale.swift',
    'src/ios/Shared/AppearanceThemeShuffle.swift',
]
for path in targets:
    src = open(path, encoding='utf-8').read()
    keys = set(re.findall(r'AppLocalized\(\s*"((?:[^"\\]|\\.)*)"', src))
    missing = sorted(k for k in keys if k not in cat)
    if missing:
        bad += 1
        print('FAIL E-1: %s 缺 %d 条: %s' % (path, len(missing), missing[:8]))
for path in targets:
    src = open(path, encoding='utf-8').read()
    for m in re.finditer(r'return "([^"]*[\u4e00-\u9fff][^"]*)"', src):
        print('FAIL E-1: %s 还有裸中文 return: %s' % (path, m.group(1)))
        bad += 1
if bad:
    sys.exit(1)
EOF
    end E-1
fi

# --------------------------------------------------------- E-2 明暗初值
if want E-2; then
    begin
    f=src/ios/Views/Settings/AppearanceStudioView.swift
    grep -q 'variant = studio.activeVariant' "$f" || bad E-2 'onAppear 没有同步 activeVariant'
    grep -q 'variantPinnedByUser' "$f" || bad E-2 '没有「用户手动切过」的标记'
    end E-2
fi

# ------------------------------------------------------ A-1 立绘落文件
if want A-1; then
    begin
    f=src/ios/Shared/AppearanceThemePack.swift
    b=src/ios/NativeOffloads/ThemeOffloadBridge.swift
    grep -q 'character-art.jpg' "$f" || bad A-1 '立绘没有落成文件'
    grep -q 'stored.characterArtBase64 = nil' "$f" || bad A-1 'applyThemePack 没剥立绘'
    grep -q 'removeValue(forKey: "characterArtBase64")' "$b" || bad A-1 'minis-theme get 还在吐立绘 base64'
    end A-1
fi

# -------------------------------------------------------- A-2 图标路径消毒
if want A-2; then
    begin
    grep -q 'sanitizedIconID' src/ios/Shared/AppearanceStudio.swift \
        || bad A-2 'customIconFileURL 没消毒 id'
    # 只看非注释行：注释里引用了旧写法作说明
    grep -v '^\s*///' src/ios/Shared/AppearanceStudio.swift \
        | grep -Fq 'appendingPathComponent("\(id).png")' \
        && bad A-2 '还在用未消毒的 id 拼路径'
    end A-2
fi

# ------------------------------------------------ B-2 / D-3 主题库反馈
if want B-2; then
    begin
    f=src/ios/Views/Settings/AppearanceStudioView.swift
    grep -q 'pendingDeleteTheme' "$f" || bad B-2 '删主题没有二次确认'
    end B-2
fi
if want D-3; then
    begin
    f=src/ios/Views/Settings/AppearanceStudioView.swift
    grep -q '_ = studio.saveCurrentTheme' "$f" && bad D-3 'saveCurrentTheme 返回值还在丢'
    grep -q '_ = studio.applySavedTheme' "$f" && bad D-3 'applySavedTheme 返回值还在丢'
    grep -q 'MinisToast.show' "$f" || bad D-3 '主题库操作没有结果提示'
    end D-3
fi

# --------------------------------------------------- C-2 minis-theme 进目录
if want C-2; then
    begin
    grep -q 'id: "minis-theme"' src/ios/Agent/Chat/AIChatViewModel+ToolDefinitions.swift \
        || bad C-2 'minis-theme 不在工具目录'
    end C-2
fi

# --------------------------------------------------- C-1 手册入口对齐
if want C-1; then
    begin
    f=src/ios/Resources/user-manual.md
    grep -q 'AI 主题包' "$f" && bad C-1 '手册还写着不存在的「AI 主题包」入口'
    grep -q '主题库' "$f" || bad C-1 '手册没写真正的入口（主题库）'
    end C-1
fi

if [ "$FAIL" -ne 0 ]; then
    echo "---- 有断言失败"
    exit 1
fi
echo "---- 全部通过"
