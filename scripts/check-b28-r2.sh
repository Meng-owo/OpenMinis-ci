#!/bin/sh
# [B28 round 2] 13 条断言，全部围绕一句话：功能必须诚实（醒醒 10-23 定的尺）。
# 用法：在仓库根跑 `sh scripts/check-b28-r2.sh`。
# 规则：每条先在基线（未修）上 FAIL，修完 PASS。任何一条修完还红 = 没修好。
# 和 round 1 的 check-b28.sh 一样，只用 grep 可验证的结构事实，不猜语义。
cd "$(dirname "$0")/.." || exit 2
V=src/ios/Views/Settings/AppearanceStudioView.swift
S=src/ios/Shared/AppearanceStudio.swift
L=src/ios/Shared/AppearanceThemeLibrary.swift
P=src/ios/Shared/AppearanceThemePack.swift
X=src/ios/NativeOffloads/ThemeOffloadExtras.swift
B=src/ios/NativeOffloads/ThemeOffloadBridge.swift
CAT=src/ios/Localizable.xcstrings
fail=0
ok()   { printf 'OK   %s\n' "$1"; }
bad()  { printf 'FAIL %s\n' "$1"; fail=$((fail+1)); }

# R2-1 「恢复默认色盘」不许裸调用：必须先进确认（B-11）
if rg -q "pendingPaletteReset" "$V" && ! rg -q "^\s+studio\.resetColors\(\)$" "$V"; then
  ok R2-1 ; else bad "R2-1 恢复默认色盘仍是裸调用，无确认"; fi

# R2-2 setWallpaper 不许吞失败：签名必须表态（B-12）
if rg -q "func setWallpaper\(.*\) -> Bool" "$S"; then ok R2-2a; else bad "R2-2 setWallpaper 仍无返回值"; fi
# 每个图片 setter 的失败分支都要 fail(...)：数调用点，不看注释
if [ "$(rg -c 'fail\(AppLocalized\("选中的图读不出来。"\)' "$V")" -ge 5 ]; then ok R2-2b; else bad "R2-2 UI 侧图片失败提示不够 5 处"; fi

# R2-3 满 40 不许静默删最旧（B-14）
if rg -q "func saveCurrentTheme\(name: String\? = nil\) -> AppearanceSavedTheme\?" "$L" \
   && ! rg -q "for extra in list.suffix" "$L"; then
  ok R2-3 ; else bad "R2-3 主题库满仍会静默顶掉最旧一套"; fi

# R2-4 恢复默认主题包的文案必须提透明度滑杆（B-10）
if rg -q "opacity sliders" "$V" "$CAT"; then ok R2-4; else bad "R2-4 重置文案仍不提三个透明度滑杆"; fi

# R2-5 换 App 图标失败不许打勾（E-10）
if rg -q "setAlternateIconName" "$V" && rg -A8 "setAlternateIconName" "$V" | rg -q "guard let error|if let error"; then
  ok R2-5 ; else bad "R2-5 图标失败仍然照样打勾"; fi

# R2-6 分类图标行不许把英文 key 直接给用户看（E-7）
if ! rg -q "Text\(key\)" "$V" && rg -q "categoryDisplayName" "$V"; then
  ok R2-6 ; else bad "R2-6 分类图标还在显示 code/writing 这种英文 key"; fi

# R2-7 CLI 删不存在的 slot 不许报成功（A-3）
if rg -q "no_icon_for_slot" "$X" || rg -q "existed" "$X"; then
  ok R2-7 ; else bad "R2-7 CLI 对不存在的 slot 仍回 ok:true"; fi

# R2-8 UI 必须有重命名入口（长按菜单）
if rg -q "renameSavedTheme\(" "$V" && rg -q "contextMenu" "$V"; then
  ok R2-8 ; else bad "R2-8 主题库没有重命名入口"; fi

# R2-9 壁纸来源必须三选一、状态可见（D-4）
if rg -q 'Text\(AppLocalized\("跟随全局"\)\)' "$V" && ! rg -q 'AppLocalized\("改用继承的背景"\)' "$V"; then
  ok R2-9 ; else bad "R2-9 壁纸还是两个看不懂的红按钮"; fi

# R2-10 列表三态：使用中 / 已改（D-2 的诚实版）
if rg -q "lastAppliedLibraryID" "$L" && rg -q "In use" "$V"; then
  ok R2-10; else bad "R2-10 主题库不显示当前用的是哪套"; fi

# R2-11 装扮页任意子页都能一键「存」（D-5 的诚实版：弹名字框，不自动起名）
if rg -q "inputDialog" "$V" && rg -q "toolbar" "$V"; then
  ok R2-11; else bad "R2-11 顶栏没有一键存"; fi

# R2-12 撤销快照必须真的含三个透明度（B-10 的撤销谎言）
if rg -A30 "func captureThemeUndoSnapshot" "$P" | rg -q "surfaceOpacity"; then
  ok R2-12; else bad "R2-12 撤销救不回透明度滑杆"; fi

# R2-13 本轮新键九语种齐全（E-1 的延续：新文案不许再只中英）
MISS=$(python3 scripts/check_b28_r2_locales.py 2>&1)
RC=$?
if [ "$RC" -ne 0 ]; then
  bad "R2-13 语种检查脚本出错: $(echo "$MISS" | head -2 | tr '\n' ' ')"
elif [ -n "$MISS" ]; then
  bad "R2-13 新键语种缺失: $(echo "$MISS" | head -3 | tr '\n' ' ')"
else
  ok R2-13
fi

echo "----"
if [ "$fail" -gt 0 ]; then echo "$fail FAILED"; exit 1; else echo "全部通过"; fi
