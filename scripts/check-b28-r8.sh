#!/usr/bin/env bash
# [10-23 醒醒 R8] 四条体感问题的回归断言。
# 她原话：① 用户气泡展开/收起屏幕一跳一跳 ② AI 代码块展开挡着气泡
# ③ 滑动看上下文一卡一卡、自己跳到没滑到的位置 ④ 她自己发的代码块没了
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
fail=0
ok() { echo "  ok  $1"; }
bad() { echo "  FAIL $1"; fail=$((fail + 1)); }

C=src/ios/Views/Chat/ChatMessageViews.swift
V3=src/ios/Agent/MessageList/CollectionViewMessageListV3.swift
L=src/ios/Agent/MessageList/MessageListLayout.swift
S=src/ios/Views/Chat/SelectableMarkdownView.swift
A=src/ios/Views/Chat/AssistantBlockView.swift
# [B28 R10] 固定高度卡片 + 全屏编辑 + 加号恢复，涉及的另外几处
CE=src/ios/Agent/Chat/AIChatViewModel+CodeBlockEditing.swift
AV=src/ios/Views/Chat/AIChatView.swift
AS=src/ios/Shared/AppearanceStudio.swift
CM=src/ios/Views/Chat/ChatMessageViews.swift

# R8-1 自带围栏（``` / ~~~）的代码也要走代码块
if rg -qF 'UserCodeFencing.hasFence(text) || UserCodeFencing.autoFenced(text) != text' "$C"; then
  ok R8-1; else bad "R8-1 用户自带围栏的代码还会被当纯文本"; fi

# R8-1b [B28 R10 改判据] 视图和列表预计算共用同一个代码判据、同一套分段。
# 测高不再是"量代码行数"——R10 起代码块是固定高度卡片（对齐声音卡片），
# 所以判据改成：两边都取同一个 cardHeight 常量，且该常量来自声音卡片同源。
# 原来断言 measuredHeight(...) 是 R9 展开式设计的一部分，R10 已废弃该设计。
if rg -qF 'let hasCode = UserMessageText.hasCode(text)' "$V3" \
   && rg -qF 'ChatCodeBlockView.cardHeight' "$V3" \
   && rg -qF 'static let cardHeight = VoiceCatBubbleCardView.cardHeight' "$A" \
   && rg -qF 'ChatMarkdownSegmenter.segments(from: fenced)' "$V3"; then
  ok R8-1b; else bad "R8-1b 预计算/视图的代码判据或卡片高度不同源"; fi

# R8-2 展开/收起量出新高度后走动画，不再硬跳
if rg -qF 'private func animateCellResize' "$V3" \
   && rg -qF 'layout.setTransitionHeight(height, at: indexPath.item)' "$V3" \
   && rg -qF 'UIView.animate(withDuration: duration' "$V3"; then
  ok R8-2; else bad "R8-2 展开仍走硬改高度"; fi

# R8-7 AI 代码块展开同步长高宿主 cell
if rg -qF 'invalidateCellSizeIfNeeded(animated: true)' "$S" \
   && rg -qF 'private func applyAnimatedCellHeight' "$S" \
   && rg -qF 'layout.setTransitionHeight(target, at: ip.item)' "$S"; then
  ok R8-7; else bad "R8-7 代码块展开没有同步长高宿主 cell"; fi

# R8-8 滚动中不换快照，结算后按锚点回位
if rg -qF 'guard !cv.isTracking, !cv.isDecelerating else { return }' "$V3" \
   && rg -qF 'let anchorIP = cv.indexPathsForVisibleItems.min()' "$V3"; then
  ok R8-8; else bad "R8-8 快照刷新会抢滚动 offset"; fi

# R8-9 用户长文用 Kelivo 式裁剪，不换字符串
if rg -qF 'static let collapsedLineLimit = 8' "$C" \
   && rg -qF 'frame(maxHeight: collapsedMaxHeight' "$C" \
   && rg -qF 'label.numberOfLines = UserMessageText.collapsedLineLimit' "$V3"; then
  ok R8-9; else bad "R8-9 用户长文仍靠换字符串折叠"; fi

# R8-10 展开动画期间锁住自 sizing，结束再解锁
if rg -qF 'transitionLocked' "$L" \
   && rg -qF 'func unlockTransitionHeight' "$L" \
   && rg -qF 'unlockTransitionHeight(at: indexPath.item, expectedHeight: height)' "$V3" \
   && rg -qF 'unlockTransitionHeight(at: ip.item, expectedHeight: target)' "$S"; then
  ok R8-10; else bad "R8-10 动画中途会被 SwiftUI 中间帧改高度"; fi

# R8-11 用户滚动期间不整表重排流式内容
if rg -qF '滚动期间把高度变化留给 settle' "$V3"; then
  ok R8-11; else bad "R8-11 滚动中仍在做流式整表重排"; fi

# R8-3 用户气泡展开按锚点回填 offset（被点那条原地不动）
if rg -qF 'let anchorScreenY = cv.cellForItem(at: ip)' "$V3" \
   && rg -qF 'cv.contentOffset.y = min(max(newY - anchorScreenY, minOff), maxOff)' "$V3"; then
  ok R8-3; else bad "R8-3 用户气泡展开没有锚点保持"; fi

# R8-4 滚动结算按顶部可见格子反推 offset（不再只放回数字）
if rg -qF 'let target = postY - screenY' "$V3" \
   && rg -qF 'cv.contentOffset.y = min(max(target, minOff), maxOff)' "$V3"; then
  ok R8-4; else bad "R8-4 settle 仍只恢复数字 offset"; fi

# R8-5 滚动中只放行视口下方的高度变化
if rg -qF 'if originalAttributes.frame.minY < viewportBottom,' "$L" \
   && ! rg -qF 'preferred <= original + 0.5' "$L"; then
  ok R8-5; else bad "R8-5 滚动中仍放行视口内增长"; fi

# R8-6 代码块折叠后失效 TextKit 布局，否则 sizeThatFits 还是旧高度
if rg -qF 'func refreshAttachmentBounds(for view: UIView)' "$S" \
   && rg -qF '.refreshAttachmentBounds(for: wrapper)' "$S"; then
  ok R8-6; else bad "R8-6 折叠后没有失效附件布局"; fi

# R9-1 代码块已脱离 NSTextAttachment，AI/用户都走独立视图
if rg -qF 'struct ChatCodeBlockView' "$A" \
   && rg -qF 'ChatCodeBlockView(' "$A" \
   && rg -qF 'ChatCodeBlockView(' "$C"; then
  ok R9-1; else bad "R9-1 代码块仍在 TextKit 附件里"; fi

# R9-2 [B28 R10 改判据] 分段器三处共用：助手渲染、用户渲染、列表预计算。
# 之前断言的是"预计算内部再用 ChatMarkdownSegmenter.segments(from: markdown)"
# 这种字面写法——R10 改固定高度后预计算不再逐段测高，判据失去意义。
if rg -qF 'enum ChatMarkdownSegmenter' "$A" \
   && rg -qF 'ChatMarkdownSegmenter.segments(from: fenced)' "$V3" \
   && rg -qF 'ChatMarkdownSegmenter.segments(from: fenced)' "$CM" \
   && rg -qF 'case .code(let language, let code, let codeIndex)' "$A"; then
  ok R9-2; else bad "R9-2 分段器没有同时服务助手/用户渲染和预计算"; fi

# R9-3 [B28 R10 改判据] 卡片高度必须与声音卡片同源，且不再是"折叠态进缓存键"。
# R10 取消展开/折叠动画（展开推挤会闪屏），高度恒定 → 缓存键不需要折叠态。
# 这条改为守死"两个卡片高度同源"，防止以后有人单边改数值。
if rg -qF 'static let cardHeight = VoiceCatBubbleCardView.cardHeight' "$A" \
   && rg -qF '.frame(height: Self.cardHeight' "$A"; then
  ok R9-3; else bad "R9-3 代码块卡片高度没和声音卡片同源"; fi

# R9-4 [B28 R10 改判据] 放大全屏链路必须接上：卡片按钮 → 全屏详情 → 可编辑保存。
# 原来这条守的是"展开有独立通知 + 列表动画重测"，R10 已删除该动画。
if rg -qF 'ChatCodeBlockExpandRouter' "$A" \
   && rg -qF 'struct ChatCodeBlockDetailView' "$A" \
   && rg -qF 'ChatCodeBlockEditRouter' "$A" \
   && rg -qF 'func saveEditedCodeBlock' "$CE" \
   && rg -qF '.fullScreenCover(item: $codeBlockCover)' "$AV" \
   && rg -qF 'ChatCodeBlockExpandRouter.expandedNotification' "$AV"; then
  ok R9-4; else bad "R9-4 代码块放大/全屏/保存链路没接上"; fi

# R10 新增：加号里的"压缩上下文/清空对话"必须还在（历史上被误删过）
if rg -qF 'case .compactHistory' "$AV" && rg -qF 'vm.compactAll()' "$AV" \
   && rg -qF 'case .clearChat' "$AV" \
   && rg -qF 'clearChatConfirmRequested = true' "$AV" \
   && rg -qF '.compactHistory, .clearChat' "$AV"; then
  ok R10-1; else bad "R10-1 加号里的压缩上下文/清空对话不见了"; fi

# R10 新增：可见文案不许写死名字（称呼必须自适应）
if ! rg -q 'AppLocalized\("[^"]*(小梦|醒醒)' src/ios --glob '*.swift' \
   && rg -qF 'enum ChatAddressing' "$AS" \
   && rg -qF 'ChatAddressing.assistant(' "$CE"; then
  ok R10-2; else bad "R10-2 出现写死的名字称呼，或称呼没走自适应"; fi

echo "----"
if [ "$fail" -gt 0 ]; then echo "$fail FAILED"; exit 1; else echo "全部通过"; fi
