#!/bin/sh
# [B28 round 7] 醒醒真机三条：代码块黑线/截断/锁高度、thinking 样张真身、
# 每页自己的样张。这条脚本守「代码块三层高度公式必须逐值一致」。
cd "$(dirname "$0")/.." || exit 2
S=src/ios/Views/Chat/SelectableMarkdownView.swift
V=src/ios/Views/Settings/AppearanceStudioView.swift
fail=0
ok()  { printf 'OK   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1"; fail=$((fail+1)); }

# R7-1 attachmentBounds 与 makeView 的 topOffset 必须同为 32/14（黑线根因是 28/32 差 4pt）
if rg -qF '? 32 : 14' "$S" && ! rg -qF '? 28 : 12' "$S"; then
  ok R7-1; else bad "R7-1 attachmentBounds 与 makeView 头部高度不一致"; fi

# R7-2 展开态 = 全量高度（不再有 400pt 封顶窗口）
if rg -qF 'collapsed ? metrics.collapsedHeight : metrics.fullHeight' "$S" \
   && ! rg -q 'min\(metrics\.fullHeight, metrics\.maxCodeHeight\)' "$S" \
   && ! rg -qF '400 - topOffset' "$S"; then
  ok R7-2; else bad "R7-2 展开态还有封顶窗口"; fi

# R7-3 maxCodeHeight 字段彻底下线（只许注释里出现）
n=$(rg -c 'maxCodeHeight' "$S" 2>/dev/null || echo 0)
if [ "$n" -le 1 ]; then ok R7-3; else bad "R7-3 maxCodeHeight 残留 $n 处"; fi

# R7-4 折叠渐变整块删掉（醒醒 10-23 二次反馈：那条灰带就是它），
# 折叠高度改字体度量算
if ! rg -qF 'fadeViewTag' "$S" \
   && rg -qF 'n * theme.codeBlockFont.lineHeight + max(0, n - 1) * 4' "$S"; then
  ok R7-4; else bad "R7-4 渐变遮罩没删干净或折叠高度还在另建 UITextView 量"; fi

# R7-5 updateExistingView 的高度公式与展开态同式
if rg -qF 'let newTotal = metrics.topOffset + metrics.fullHeight + metrics.bottomPadding' "$S"; then
  ok R7-5; else bad "R7-5 updateExistingView 高度公式没跟上"; fi

# R7-6 thinking 样张点开弹真抽屉，高度档位与聊天一致
if rg -qF '.presentationDetents([.fraction(2/3), .large])' "$V"; then
  ok R7-6; else bad "R7-6 样张抽屉档位与聊天不一致"; fi

# R7-7 用户气泡走新组件（代码自动成块 + 长文折叠）
C=src/ios/Views/Chat/ChatMessageViews.swift
if rg -qF 'UserMessageText(text: userDisplayText' "$C" && rg -qF 'enum UserCodeFencing' "$C"; then
  ok R7-7; else bad "R7-7 用户气泡没走新组件"; fi

# R7-8 自动补栅栏 + 长文折叠阈值都在（折叠判定只此一份）
if rg -qF 'static func autoFenced' "$C" && rg -qF 'static func isLongText' "$C" \
   && rg -qF 'text.count > 320' "$C"; then
  ok R7-8; else bad "R7-8 代码识别或长文阈值缺失"; fi

# R7-13 识别器语料：30 段真代码全中，44 段真散文零误报
if python3 scripts/check-code-detect.py | rg -q '误报 0 漏判 0'; then
  ok R7-13; else bad "R7-13 代码识别语料不过（误报或漏判）"; fi

# R7-14 代码块统一：无行号、恒换行、无横向滚动
M=src/ios/Views/Chat/SelectableMarkdownView.swift
if ! rg -q 'gutterAttributedText|makeGutterTextView' "$M" \
   && rg -qF 'static func gutterWidth(forLineCount lineCount: Int) -> CGFloat { 0 }' "$M" \
   && ! rg -q 'codeBlockWrapEnabled' "$M" src/ios/Shared/AppearanceThemePack.swift \
   && rg -qF 'showsHorizontalScrollIndicator = !wrapEnabled' "$M"; then
  ok R7-14; else bad "R7-14 代码块还有行号或换行开关残留"; fi

# R7-15 展开态进高度键 + 预计算跟着折叠态走
VC=src/ios/Agent/MessageList/CollectionViewMessageListV3.swift
if rg -qF 'UserBubbleExpansion.shared.isExpanded(id) ? 1 : 0' "$VC" \
   && rg -qF 'UserMessageText.collapsedLineLimit' "$VC"; then
  ok R7-15; else bad "R7-15 折叠态没接进高度链路"; fi

# R7-9 展开/收起两条文案九语种齐
if python3 -c 'import json,sys
c=json.load(open("src/ios/Localizable.xcstrings",encoding="utf-8"))["strings"]
w={"de","en","es","fr","ja","ko","ru","zh-Hans","zh-Hant"}
bad=[k for k in ["展开全文","收起"] if w-set(c.get(k,{}).get("localizations",{}))]
sys.exit(1 if bad else 0)'
then ok R7-9; else bad "R7-9 展开/收起文案语种不齐"; fi

# R7-10 用户气泡展开：状态在共享存储 + 发通知让列表重算
C=src/ios/Views/Chat/ChatMessageViews.swift
V3=src/ios/Agent/MessageList/CollectionViewMessageListV3.swift
if rg -qF 'final class UserBubbleExpansion' "$C" \
   && rg -qF 'userBubbleToggled' "$C" \
   && rg -qF 'for: .userBubbleToggled' "$V3" \
   && rg -qF 'case .wholeMessage(let mid) = item, mid == messageId' "$V3"; then
  ok R7-10; else bad "R7-10 用户气泡展开没接列表重算"; fi

# R7-11 thinking 样张不再自己画卡片（真身是 TurnSummaryRow + TurnDetailSheet）
if ! rg -qF 'MinisThemeShape.thinkingFill' "$V" \
   && [ "$(rg -c 'TurnSummaryRow\(' "$V")" -ge 2 ]; then
  ok R7-11; else bad "R7-11 样张里还有自绘的 thinking 卡片"; fi

# R7-12 闪退：SwiftUI 用 ∞ 探尺寸时不许把非有限值喂进 Int（SIGTRAP）
if rg -qF 'static func safeBucket' "$S" \
   && rg -qF 'proposedRaw.isFinite && proposedRaw > 0' "$S" \
   && ! rg -q 'widthBucket: Int\(|let widthKey = Int\(width' "$S"; then
  ok R7-12; else bad "R7-12 还有非有限宽度直接转 Int 的路径"; fi

echo "----"
if [ "$fail" -gt 0 ]; then echo "$fail FAILED"; exit 1; else echo "全部通过"; fi
