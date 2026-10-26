#!/bin/sh
# [B28 round 5] 预览试点：样张必须是真的 —— 嵌的是聊天页同款组件，不是复刻。
cd "$(dirname "$0")/.." || exit 2
V=src/ios/Views/Settings/AppearanceStudioView.swift
C=src/ios/Views/Chat/ChatMessageViews.swift
fail=0
ok()  { printf 'OK   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1"; fail=$((fail+1)); }

# R5-1 thinking 样张 = 真身（合并行 + 点开真抽屉）
# [B28 R7 醒醒实拍 10-23] 聊天里 thinking 早已不是折叠卡片 ThinkingBlockView，
# 真身是 TurnSummaryRow 合并行、点开弹 TurnDetailSheet 抽屉。样张跟着真身走。
if rg -qF 'TurnSummaryRow(' "$V" && rg -qF 'TurnDetailSheet(message: previewTurnMessage)' "$V" && ! rg -qF 'ThinkingBlockView(block: previewThinkingBlock' "$V"; then ok R5-1; else bad "R5-1 thinking 样张不是真身"; fi

# R5-2 AI 样张 = 真 AssistantBlockView（含 Markdown 渲染与显示形态判定）
if rg -qF 'AssistantBlockView(block: previewAssistantMessage.blocks[0]' "$V"; then ok R5-2; else bad "R5-2 AI 气泡样张不是真组件"; fi

# R5-3 用户样张 = 真 UserBubbleSurface 皮肤，且它已开内部可见
if rg -qF '.modifier(UserBubbleSurface(isQueued: false))' "$V" && rg -q '^struct UserBubbleSurface: ViewModifier' "$C"; then
  ok R5-3; else bad "R5-3 用户气泡样张没复用真皮肤或可见性没开"; fi

# R5-4 样张文本九语种齐
if python3 - "$V" <<'PY'
import json,sys,re
need=["今晚月色真美呀","也真的想你",
      "这张不是画的样张，是聊天里那张真卡——同一份代码，换主题一起换。",
      "样张 · 实时"]
c=json.load(open('src/ios/Localizable.xcstrings',encoding='utf-8'))["strings"]
want={"de","en","es","fr","ja","ko","ru","zh-Hans","zh-Hant"}
missing=[f"{k}:{','.join(sorted(want-set(c.get(k,{}).get('localizations',{}))))}" for k in need if want-set(c.get(k,{}).get('localizations',{}))]
print("; ".join(missing)); raise SystemExit(1 if missing else 0)
PY
then ok R5-4; else bad "R5-4 样张文案语种不齐"; fi

# R5-5 通讯录呼吸灯 + 「内置」批下线（醒醒 10-23 点名：要动画、出身不是关系）
C2=src/ios/Views/Chat/PersonaContactsView.swift
if rg -q 'symbolEffect\(.pulse, options: .repeating\)' "$C2" && ! rg -q 'Text\("内置"\)' "$C2"; then
  echo "OK   R5-5"; else echo "FAIL R5-5 呼吸灯没亮或内置批还挂着"; exit 1; fi

echo "----"
if [ "$fail" -gt 0 ]; then echo "$fail FAILED"; exit 1; else echo "全部通过"; fi

