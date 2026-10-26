
## R22 媒体库内容去重（a5acf77）

来源：醒醒截图，播放页一张头像列出了十几张一模一样的图。
根因：换头像每写一次就留一个新 UUID 文件，历史压缩版也没删，扫描只按路径去重。
做法：`PlayHubView` 新增 `dedupeByContent` / `fingerprint` / `preferred` / `isUUIDLike`。
先按 size 分组，只有同 size 才读前 64KB 做 FNV-1a，600 张里实际读盘的是少数。
组内保留 `/uploads/` 原件，其次非 UUID 文件名的。
只改显示层；磁盘上的旧副本没动（清理要改数据库引用，等醒醒点头）。

## R23 一起听地基（5516d40）

TASK.md 七步流程，0-2 步已过：复述任务、缺信息一次问全、计划贴出。
数据源定案：AI 上网找歌+歌词，或醒醒上传（无词则补），增删改都落本地，不绑别的 App，留 `MusicImporter` 口子。

状态层先用 Python 跑通再搬 Swift：
- `/var/minis/shared/together/together.py`：flock + 原子写 + revision，命令 status/get/set/play/pause/resume/seek/note/mood/reply/radio/events/history
- `/var/minis/shared/together/test/state.py`：14 项自检全绿
  - 并发写入改用 25 批 ×4 进程：iSH 4GB 扛不住 100 个 python 同时起（MemoryError），不是锁失效
  - 坏文件恢复补 `_recover`：备份完立刻落默认值，不留"文件不存在"的窗口

Swift 侧（`src/ios/Agent/Together/`）：
- `TogetherState.swift`：模型逐字段对齐 state.json，全部 `decodeIfPresent` + 默认值，单字段坏不拖垮整份
- `TogetherStore.swift`：`hostPath(forGuestPath:)` 做 guest→host 映射，共享目录不可写降级沙盒并记日志；
  `mutate(by:event:detail:)` 统一 revision+1、事件追加、帧数封顶；场景动作 play/seek/like/note/radio/mood/speak
  speak 三句封顶在写盘前判
- 自审修三处：`FileHandle(forUpdating: fd)` 是错 API → 直接 fd + flock；fsync 漏 fd → 用 `Data.write(.atomic)`；
  speak 第四句仍落空事件 → 先判再写

CI：`build-ios-ipa.yml` dispatch ref=drawer-113，验证编译。

## R24-R33 一起听（Together）

TASK.md 七步走完：意图复述 → 缺信息一次问全 → 计划 → 调研 → 审计 → 动手 → 复审。
数据源定案：AI 上网找歌+歌词 / 醒醒上传（无词则补），增删改全落本地，
不绑别的 App，留 `MusicImporter` 协议做口子。

### 状态层（R23 起，Python 跑通再搬 Swift）
- `/var/minis/shared/together/together.py`：flock + 原子写 + revision，命令
  status/now/get/set/play/pause/resume/seek/note/mood/reply/radio/handoff/playlist/lib/skin/events/history/loopline
- `test/state.py`：14 项全绿（并发 100 次不丢、坏文件备份+重建、事件封顶 500、revision 单调）
- Swift `TogetherState.swift`：模型逐字段对齐 state.json，全 decodeIfPresent + 默认值
- Swift `TogetherStore.swift`：flock + 原子写，`mutate` 统一 revision/事件/封顶；场景动作 play/seek/like/note/radio/mood/speak/playlist

### 路径（踩过的坑）
- `/var/minis` 在 App 侧 = `Documents/alpine-rootfs/data/var/minis`（由 mount 输出实证）
- 第一版：探测不到共享根就缩回沙盒 → 面板一直"还没有歌"。改成建目录 + 试写探针才判定
- 写共享目录要走 `FakefsBridge` 登记 `alpine-rootfs/meta.db` 的 paths/stats，
  否则 iSH 侧看不见 App 写的 state（SkillStore 里 ensureFakefsMetadata 同一件事）
- `rootDecision` 两处判定比的中文字符串还不一样 → 收成 `isSharedRoot` 布尔

### 音频（R24）
- `TogetherPlayer.swift`：独立 AVPlayer 引擎，不复用语音气泡那套
- 后台靠 AudioSessionCoordinator + Info.plist audio mode（已有）
- `VoiceNowPlaying` 加一起听分支并优先：音乐长播，锁屏该显示歌名不被语音消息顶掉

### 界面（R25-R29）
- `TogetherPanelView`：播放页照 reference.html 01 屏，双人头像 104、五键控制、底部四功能
- `TogetherRootView`：底部标签栏串 在听/歌单/一起/喜欢
- `TogetherScreens`：歌单库 / 歌单详情 / 我喜欢的音乐 / 一起听 / 编辑面板 / 加歌
- `TogetherMiniBar`：悬浮小卡 250x72，贴边收起成 12pt 竖条
- `TogetherSkin`：皮肤层（唱片深浅/纹路/圆角/阴影）+ `TogetherCopy` 文案层 + `TogetherIdentity` 头像单一取法

### 共感与工具（R28/R30）
- 事件流：她的每次切歌/拖动/喜欢都落一条，我读得到
- `me.presence`：我在不在、什么心情、想不想说话
- `me.history`：我推过的歌+理由，下一回合读得到
- `reply` 一天三句封顶（写盘前判，超了不落空事件）
- `now` 命令给的是判断不是字段表
- `soulEditHint` 补 TOGETHER 段，全部参数核对过

### 自审修的真问题
- R25b：Swift 字符串 `\/` 非法转义
- R25c：`ChatFont.font(size:)` 参数无标签，20 处报错；唱片五层叠加 type-check 超时 → 拆 `TogetherDiscView`
- R25d：`TogetherSkin` 取值入口是 @MainActor，跟着标
- R27：`TogetherTrack` 补 Identifiable；`TogetherCover` 标 @MainActor
- R29b：`TogetherPlaylist` 不是 Hashable，导航改 `NavigationLink(value:)`
- R32：跟随比 revision 会被进度回写反复触发 → 改比事件 id；冷启动无条件 play → 尊重 state 的暂停
- R33：`restoreIfNeeded` 冷启动接着放

### 曲库
真歌三首（archive.org 公有领域 / CC 授权，含来源标注）：
Gymnopédie No.1、Frogs Legs Rag、Danny Boy。
无词的两首用 `loopLines` 循环一句我写的话。
`together-fetch.py`：import（视频抽音轨）/ lyrics（lrclib 带时间轴）/ search / list。
抓不到歌词就留空，不编。

---

## 当前状态交接（压缩上下文前落盘）

### 已完成并推送
- 分支 drawer-113，HEAD 含 R22–R33 全部提交
- 最新成功出包：run 40155500109（R33）→ `/var/minis/attachments/OpenMinis-一起听.ipa`
- 一起听六屏 + 播放引擎 + 悬浮小卡 + 状态层 + AI 工具面，代码全在
- `/var/minis/shared/together/test/acceptance.py` 41 项自检全绿（在 agent 沙盒里跑）

### 关键认知纠正（很重要）
- **agent 的 /var/minis 和她手机上 OpenMinis 的容器不是同一个沙盒。**
  我这边是另一个 App（嘟嘟）的沙盒，看不到她运行时的 state.json。
  所以：只有她 App 里 AI 跑出来的输出，才是我能看到的运行时事实。
  我这边 `/var/minis/shared/together/` 的曲库和 state 只是我的副本，不会随 IPA 发出去。

### 未解决的问题（按怀疑顺序）
1. **【最可能】曲库和 state 没随 IPA 打包。**
   我把歌种在自己沙盒的 /var/minis/shared/together/，但 IPA 里没有这些文件。
   她装上打开必然"还没有歌"。需要在 App 首次启动时自举：
   建目录 + 写一份默认 index.json（带 1-2 首随包资源）+ 默认 state.json。
2. **App 建目录没登记 fakefs meta.db。**
   TogetherStore.ensureDirectories 只 createDirectory，没调 FakefsBridge.registerParents，
   里面的 shell 可能看不到这些目录。目录已存在时也要补登记。
3. **首次启动的共享目录探测。**
   rootURL 用试写探针判断，但若 shared 根不存在会降级沙盒，
   降级后 AI 的 shell 就读不到 → 需要首次就把 /var/minis/shared/together 建好并登记。
4. 她反馈"我自己这边确实遇到问题了"，但**具体现象还没说**（空/有歌点不动/闪退）。
   等她一句话描述再定，不要猜着修。

### 她的偏好（延续，别丢）
- 不急、一步一步、质量优先；只验收最终成果，不要中间包
- 一个一个问题解决，不要一次全推
- 不贴长汇报；有问题直接修，不道歉不复盘
- 可见文案不写死人名，全走 ChatAddressing
- 颜色零裸色值，全走主题变量

### 【她实测反馈 · 2026-10-25】上传本地文件进不去
现象原文：可以选中文件，但是进不去。其他没测，因为没音乐所以无法播放、无法进入下一步。
影响：这是第一个卡点，挡住后面所有验证。
排查方向（未确认）：
- fileImporter 完成回调只 guard success，失败/空结果静默 return，没有报错提示
- security-scoped resource 取用与 async 拷贝的时序
- 目标目录未建/未登记 fakefs meta.db，copyItem 静默失败
- saveLibrary 写 index.json 的路径与 library() 读取路径是否一致
- 视频/非 mp3 走 AVAssetExportSession 失败后 fallback 是否真的成功

---

## R34 需求清单（她口述，2026-10-25）

1. **路径统一（最重要，不然两套系统打架）**：复用内置 `/var/minis/shared/music`，删自造路径。
2. **本地上传进不去**：`.fileImporter` 侧载失效 → 换 `DocumentCopyPicker`（asCopy）。
3. **悬浮球改输入栏上方微控条**：删悬浮球；38pt 条：迷你黑胶(转)+音波+歌词窗+上一首/播放/下一首。固定贴输入栏上方，不再自由拖。参考 `attachments/uploads/index.html`。
4. （并入 3）要有上一首。
5. **没歌词 → AI 写台词**：每首歌 AI 写一份"台词本"存 state，可互动/聊歌背景/感受；有词显词，无词轮播台词；AI 有工具随时改。
6. 先调研说计划不动手（已完成，她批准按最稳顺序做）。
7. **进度条/按钮偏高 → 往下调**。
8. **点唱片 → 翻成整页滚动歌词**：当前句高亮居中、点句跳转、再点翻回、过渡动画。
- 我自己补：微控条加细进度线；面板底部「添加/音量」灰按钮接上；歌词页显示歌名歌手+AI 写的背景。

### 根因（已查实）
- **两套音乐目录**：内置 `shared/music` = AppGroup/MinisFileProvider/shared/music（真 bind-mount，apple-player 认）；我的 `shared/together/music` = alpine-rootfs/data 下（靠 FakefsBridge 手登记 meta.db）。→ 统一到 `AIChatViewModel.minisSharedPersistentDir`（AppGroup 或 Application Support/OpenMinisClone 回退），这才是 bind-mount 真源，**不需要再登记 meta.db**。
- **曲库两套来源**：我读 index.json，目录有歌但 index 没登记就空库。→ 改成扫目录为准，index 当缓存。
- **上传**：`DocumentCopyPicker.swift` 注释已写明侧载 `.fileImporter` 选文件没反应。

### 开工顺序（她批准）：批次一 = 1+2+3 地基，出包确认；再批次二 = UI(3/4/7/8)；再批次三 = 5 AI 台词本 + 补全。

### R34a 地基（已出包 ce66918 / run 40164790151 success）
1. **路径只留一套**：`TogetherStore.sharedRootURL = AIChatViewModel.minisSharedPersistentDir`
   - 音乐 `shared/music`（= AppGroup/MinisFileProvider/shared/music，apple-player 同源）
   - 元数据 `shared/together/{state.json,index.json,lyrics/}`
   - 删掉 `FakefsBridge` 写入与 meta.db 登记（真 bind-mount 不需要；FakefsBridge.swift 保留未引用）
   - `audioURL(for:)` 按 shared 根解析 `music/x.mp3`；TogetherPlayer 改用它
2. **曲库以目录为准**：`library()` 每次扫 `shared/music`，把目录有/index 无的补进来（id = FNV-1a 稳定哈希），
   文件被删/改名则从 index 清掉；同目录同名 `.lrc` 自动收进 `lyrics/`；播放器学到真实时长回填 index。
3. **上传修好**：`TogetherLibraryView` 的 `.fileImporter` → `DocumentCopyPicker`（asCopy），
   picker 先落 `pendingPicks`，sheet 收起后导入；`importOne` 落地扩展名按真实编码（mp3→.mp3，其它→.m4a 或原扩展名）。
4. **补入口**：歌单库加「全部歌曲」入口 + `TogetherAllSongsView`，目录里的歌直接能播（原先只能从歌单/喜欢里进）。
5. 编译闸门（Build tests compile gate）success，出包 66,412,902 → `attachments/OpenMinis-地基统一.ipa`

### 发现但未修（下一批）
- **`together` 这个 shell 命令根本不存在**：SoulStore 的 TOGETHER 说明书让 AI 用
  `together now/play/note/lib/...`，但仓库里没有任何脚本或原生 offload 实现它
  （grep loopline 只命中 Swift）。→ AI 现在无法真正操控一起听。
  建议做成原生 offload（像 apple-player），直接读写 TogetherStore。

### R34b 交互与视觉（未出包，按她要求不跑 CI）
- **自动续播**：`TogetherPlayer.handleTrackEnd()` 一首放完 → 单曲循环重放 / 随机 / 顺序下一首（到底回绕），并 `store.play` 落盘同步。
- **播放选项进状态**：`TogetherPlayback.shuffle / repeatOne`，面板和自动续播读同一份，不再各存一套。
- **点胶片 = 翻歌词页**（不再暂停）：`TogetherLyricsPage` 整页滚动，当前句高亮居中，点某句 seek，chevron 返回。
- **按钮下移**：progress 18→34、controls 22→30、bottom 20→26（×s）。
- **悬浮球换成输入栏上方微控条**：`TogetherMiniBar` 重写——38pt、19 圆角、迷你黑胶（转）+ 三根音波 + 歌词窗 + 上一首/播放/下一首 + 细进度线；`AIChatView` 里 `.padding(.bottom, inputBarHeight)` 贴着输入栏。
- **回声弹幕**：`EchoBubble` / `EchoBubbleView` 照 HTML whisperFlow（0%→0.35 缩放+下移12+模糊4+透明；50%→1；100%→0.4+上移14+模糊3），4.6s 一笔贯通、纯 Capsule 无小角；唱到 `note.at` 那一秒才触发，一次只显一个，四角轮换；顶栏「回声」可关。
- **每轮各一句**：`TogetherListen`（trackId/startedAt/userSpoke/aiSpoke），`beginListenIfNeeded` 在 `play()` 里重开一轮（换歌或隔 30 分钟），`addNote`/`speak` 都吃额度；超出弹 toast。
- **自定义图片**：`TogetherImages` 槽位约定 `shared/together/images/<slot>.<ext>`，槽位 lyrics-cover / wallpaper-now / wallpaper-library / wallpaper-sync / wallpaper-liked / cover-1..4 / cover-now / playlist-<id>；`TogetherCoverView` 有图用图、没图回落主题渐变；歌单卡长按换封面，播放页标题长按换壁纸。
- `TogetherStore` 新增 `setImage` / `clearImage` / `imageURL` / `setPlaylistImage` / `clearPlaylistImage` / `setShuffle` / `setRepeatOne`。

### 待做
- 输入栏：话筒并进发送键（无文字=语音，有文字=发送）。
- 输入栏外观对齐 index.html（可选，动 ChatInputBar 风险高，等一次可编译验证再做）。

### R34b 出包（run 40170773892 success）
- 先失败一次：`TogetherPanelView.swift:634 cannot find 'shuffle'` —— step() 里残留旧 @State，改 `state.playback.shuffle`。
- 403b834 重跑全绿，产物 66,460,185 → `attachments/OpenMinis-交互批次.ipa`

### R34c 现代播放器闭环与全面体验重构（按醒醒需求 + 原生体验）
- **原位歌词切换（图1）**：彻底废弃全屏遮罩 `TogetherLyricsPage`；顶栏与底栏常驻不动，中间大视觉区在黑胶与居中滚动歌词（`TogetherInlineLyricsView`）间原位平滑淡入淡出，点歌词空白无缝翻回黑胶。
- **控件整体沉底（图2）**：彻底解决控件悬空问题；动作行 + 进度条 + 播放控制行贴底排布，与底部保持黄金间距。
- **歌单信息完整设置页（图3）**：全新 `TogetherPlaylistEditor`，支持更换封面缩略图、名称、多选标签（tags）、1000字简介（desc）与实时字数统计。
- **歌单内删歌与级联清理**：详情页增加实时搜索；歌曲行提供右侧 `···` 菜单与长按菜单（从歌单移除 / 彻底删除）；底层 `deleteTrackPermanently` 级联清理音频文件、歌词、index.json、所有歌单引用和 liked 引用，杜绝孤儿ID。
- **输入栏微控条纯色化**：去除 `opacity(0.86)`，采用实体纯色背景，底部间隙收紧至 3pt 贴紧输入栏。
- **独立装扮中心（取代长按）**：推出 `TogetherThemeCenterView`，管理 6 个槽位；砍掉隐蔽长按；后台 `together wallpaper` CLI 接口补齐。
- **抽屉组件（`TogetherDrawers.swift`）**：历史回声墙抽屉（查看当前歌曲全部历史刻字，点击直达秒数，底部一键留言） + 播放队列抽屉（查看当前列表并随时切歌）。
- **小惊喜（心动共振）**：顶栏微挂件触碰时，全屏扩散粉色微光，向对方传递心跳与低语。

### R34c 出包成功（run 40185046034 success）
- 修复类型推断超时与编译报错：封装 onDescChanged、trackOrder、拆解 TogetherPlaylistEditor body、补齐 TogetherCopy.save。
- CI 全绿通过，产物 66,513,080 字节 -> `attachments/OpenMinis-现代播放器全面闭环.ipa`。

### R35 一轮修复（run 40198263499 success）
1. 大头像归位（黑胶上方），歌名歌手下移回黑胶下方
2. 底部动作行/进度条/控制行贴底，不再悬空
3. 歌词当前句严格居中，首尾各留半屏，布局完成后滚动
4. 歌单列表恢复 22pt 水平内边距
5. 换图改走 PhotosPicker（相册），不再跳文件夹
6. 气泡=回声墙、笔=当场刻字
7. All songs 补 ··· 与长按删除
8. 遥控器：followTick 认 playback.by；handoff 带接收方；在线状态真实
9. 后端 together now：歌名/秒数/遥控器归属/本轮开始时间
10. 语音播报开始音乐暂停、结束续播（只恢复自己暂停的）
11. 微控条焊进输入栏 VStack；歌词走马灯；只在播放时显示
12. 队列真实化（playback.queue）、封面 NSCache
13. 删正在播的歌先 stop；All songs 搜索
- 编译修复：aiName/userName/effectivePosition 缺失、filteredTracks 作用域、类型推断超时（拆 playlistTrackRow/rowTrailing/rowContextMenu）
- 产物 66,548,411 → attachments/OpenMinis-一轮修复.ipa
