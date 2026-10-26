#!/bin/sh
# [B28 round 3] 真机反馈三条：alert 层级、标题重复、内外卡片语言。
cd "$(dirname "$0")/.." || exit 2
V=src/ios/Views/Settings/AppearanceStudioView.swift
P=src/ios/Shared/AppearanceThemePack.swift
L=src/ios/Shared/AppearanceThemeLibrary.swift
fail=0
ok()  { printf 'OK   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1"; fail=$((fail+1)); }

# R3-1 主题库里的「删」必须就地弹确认：alert 得挂在子页宿主上（pageContent 链），
# 不能留在根页 List —— 真机实测挂在根页时，弹框要退回上一页才出现。
AL=$(rg -n '\.alert\(alertTitle' "$V" | head -1 | cut -d: -f1)
SV=$(rg -n 'ScrollView \{' "$V" | head -1 | cut -d: -f1)
if [ -n "$AL" ] && [ -n "$SV" ] && [ "$AL" -gt "$SV" ]; then ok R3-1; else bad "R3-1 alert 还在根页链上（行 $AL < 子页宿主 $SV）"; fi

# R3-2 页名不在左上角和内容里出现两遍：「外观」「主题库」这种重复标题清零
if ! rg -q 'navigationTitle\(AppLocalized\("Appearance"\)\)' "$V" && ! rg -q 'navigationTitle\(item\.title\)' "$V"; then
  ok R3-2; else bad "R3-2 还有重复的页面标题"; fi

# R3-3 内外卡片同一语言：圆角和系统分组列表对齐（10pt continuous、无阴影）
if rg -A20 "struct StudioCard" "$V" | rg -q "cornerRadius: 10"; then ok R3-3; else bad "R3-3 子页卡片还是另一套圆角"; fi

# R3-4 情头归属（醒醒拍板 10-23）：头像归人设体系，主题库页面不提它
if ! rg -q "情头不在这套里" "$V"; then ok R3-4; else bad "R3-4 主题库页面不该出现情头字样"; fi

# R3-5 apply 部分成功不许装全好（F-2）
if rg -q "func applyThemePack" "$P" && rg -A60 "func applyThemePack" "$P" | rg -q "warnings"; then
  ok R3-5; else bad "R3-5 apply 吞掉了没吃下的字段"; fi
if rg -q "warnings" src/ios/NativeOffloads/ThemeOffloadBridge.swift; then ok R3-5b; else bad "R3-5b CLI 侧没透出 warnings"; fi

# R3-6 文档不硬编码字段数，不再写 26（C-4）
if ! rg -q "26 个字段" src/ios/Agent/Session/SkillStore.swift src/ios/NativeOffloads/ThemeOffloadExtras.swift; then
  ok R3-6; else bad "R3-6 文档还写着 26 个字段（实际 30）"; fi

# R3-7 「改完立刻生效」不许包办需要重进的（C-6：文案说实话，机制另轮）
if rg -q "立刻生效" src/ios/Agent/Session/SkillStore.swift && rg -q "列表图标" src/ios/Agent/Session/SkillStore.swift; then
  ok R3-7; else bad "R3-7 技能文案没说实话"; fi

# R3-8 CLI save 空名字不再拿上次导入的名字当新名字（B-15）
if rg -q 'trimmed.isEmpty \? "Untitled"' "$L"; then ok R3-8; else bad "R3-8 空名保存仍回落到 pack.name"; fi

echo "----"
if [ "$fail" -gt 0 ]; then echo "$fail FAILED"; exit 1; else echo "全部通过"; fi
