#!/usr/bin/env python3
# [B28 round 2] 本轮新增/改动的文案键必须九语种齐全。
# 输出为空 = 全齐；否则每行一条缺失信息（供 check-b28-r2.sh R2-13 消费）。
import json, sys
LOCALES = ["de", "en", "es", "fr", "ja", "ko", "ru", "zh-Hans", "zh-Hant"]
# round 2 新引入或改写的键（AppLocalized 与 Text(AppLocalized(...)) 双语境源）
KEYS = [
    # 图片失败吭声（B-12/B-13）—— 复用基线已有键，列在此防回归
    "选中的图读不出来。",
    # 重置文案说实话（B-10）
    "Colors, bubble shapes, stickers, and the three opacity sliders go back to default. Wallpaper and couple avatars stay.",
    # 满 40 拒绝（B-14）
    "The library is full (40). Delete one theme first.",
    "另存一份，不会冲掉正在用的。",
    "另存一份，不会冲掉正在用的。存满四十套会先要你删一套。",
    # 图标失败回滚（E-10）
    "Couldn't change the app icon.",
    # 壁纸三选一（D-4）
    "壁纸来源", "本页图", "跟随全局", "无背景", "清除壁纸",
    # 列表三态（D-2 诚实版）
    "In use", "In use · modified",
    # 一键存 + 长按重命名（D-5/D-1 诚实版）
    "Save as new theme", "Name it", "Rename theme", "Rename", "Save",
    "Saved “%@”", "Renamed “%@”", "名字不能是空的。",
    # 色盘重置确认（B-11）
    "Reset the color palette?", "Clear every palette tweak. You can undo right after.",
    "色盘已恢复默认，点下面可以撤销。", "已撤销。", "撤销上一次恢复",
    # 第 3 轮地基（C-3/F-2）
    "thinking 卡片", "输入栏", "没接住：%@", "情头不在这套里。",
    # 分类图标中文名（E-7）
    "编程", "写作", "调研", "分析", "创作", "闲聊", "数学", "翻译",
    "健康", "金融", "旅行", "教育", "设计", "效率", "客服", "其他",
]
cat = json.load(open(sys.argv[1] if len(sys.argv) > 1
                     else "src/ios/Localizable.xcstrings", encoding="utf-8"))["strings"]
for k in KEYS:
    locs = cat.get(k, {}).get("localizations", {})
    missing = [lc for lc in LOCALES if lc not in locs]
    if k not in cat:
        print(f"key missing entirely: {k}")
    elif missing:
        print(f"key {k} missing locales: {','.join(missing)}")
