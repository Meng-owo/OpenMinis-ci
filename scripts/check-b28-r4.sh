#!/bin/sh
# [B28 round 4] 通讯录接进主题系统（醒醒拍板 B：独立壁纸槽位）+ 简介清洗。
# 这轮先改了代码后补的断言 —— 定位是回归护栏，防以后动坏，不假装是红绿流程。
cd "$(dirname "$0")/.." || exit 2
S=src/ios/Shared/AppearanceStudio.swift
C=src/ios/Views/Chat/PersonaContactsView.swift
M=src/ios/NativeOffloads/ThemeOffload.m
CAT=src/ios/Localizable.xcstrings
fail=0
ok()  { printf 'OK   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1"; fail=$((fail+1)); }

# R4-1 persona 槽位存在且有显示名
if rg -q "case global, home, chat, settings, browser, files, terminal, bottomBar, persona" "$S" \
   && rg -q 'case .persona: return AppLocalized\("通讯录"\)' "$S"; then ok R4-1; else bad "R4-1 persona 槽位或标题缺失"; fi

# R4-2 通讯录页真的挂上背景（挂在主列表，不是随便哪个 List）
if rg -A2 -F "listStyle(.insetGrouped)" "$C" | rg -qF "appearancePage(.persona)"; then ok R4-2; else bad "R4-2 通讯录没接上主题背景"; fi

# R4-3 简介走清洗，清洗函数不许吃转义事故（Swift 源里必须是 \\s）
if rg -q "return Self.cleanBio\(bio\)" "$C" && rg -q 'of: "\\\\s\*\\\\|\\\\s\*"' "$C"; then
  ok R4-3; else bad "R4-3 简介清洗没接上或正则转义坏了"; fi

# R4-4 CLI --help 的 scope 列表带 persona
if rg -q "terminal bottomBar persona" "$M"; then ok R4-4; else bad "R4-4 CLI 帮助没列 persona"; fi

# R4-5 「通讯录」九语种齐
if python3 - "$CAT" <<'PY'
import json,sys
locs=json.load(open(sys.argv[1],encoding='utf-8'))["strings"].get("通讯录",{}).get("localizations",{})
need={"de","en","es","fr","ja","ko","ru","zh-Hans","zh-Hant"}
missing=need-set(locs)
print(("通讯录 缺: "+",".join(sorted(missing))) if missing else "")
raise SystemExit(1 if missing else 0)
PY
then ok R4-5; else bad "R4-5 「通讯录」语种不齐"; fi

echo "----"
if [ "$fail" -gt 0 ]; then echo "$fail FAILED"; exit 1; else echo "全部通过"; fi
