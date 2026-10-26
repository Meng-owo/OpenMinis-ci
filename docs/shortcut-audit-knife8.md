# 分身捷径审计（2026-09-06 · 刀8）

## 表

| 面 | 状态 | 说明 |
|---|---|---|
| 会话 list/search/messages | 通 | SessionsOffload |
| 会话 send/retry/status/open | 通 | 必须显式 UUID |
| **当前会话** | **无→本刀通** | shell 看不见前台聊天 |
| 模型 ModelUse | 通 | |
| 剪贴板 CLI | 通 | ClipboardOffload |
| 通知 | 通 | 刀4 + NotificationOffload |
| 浏览器 | 通 | BrowserUse |
| 配置 minis-config | 通 | |
| Agent 工具表直调 CLI | 半残 | 多靠 shell_execute，不是缺二进制 |

## Top1（本刀）

**当前会话捷径**：`minis-sessions-cli current`；`--session current` / `--id current` / `open current`。  
数据源：`AIChatViewModel.activeSessionId`，回落 `MINIS_SESSION_ID`。

## 用法

```bash
minis-sessions-cli current
minis-sessions-cli send "你好" --session current
minis-sessions-cli messages --id current --limit 5
minis-sessions-cli status --id current
minis-sessions-cli open current
```

无前台会话 → `no_current_session`。
