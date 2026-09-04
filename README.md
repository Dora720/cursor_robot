# cursor_robot

Cursor Agent 完成后（或 Cloud Agent 需要确认时），通过飞书应用机器人往指定群发卡片。

- 服务地址：https://cursor-robot.onrender.com
- 仓库：https://github.com/Dora720/cursor_robot

## 它做什么

1. **本地 Agent**：每台电脑安装 Cursor hook。Agent 一轮结束时，hook 通知 Render，再发飞书。
2. **Cloud Agent**：Render 服务轮询 Cursor API，完成 / 失败 / 需要确认时发飞书。

本地 Agent 的事件只存在于那台电脑，所以每台要跑本地 Agent 的机器都要装一次 hook。飞书文案、Cloud Agent 逻辑只在服务器上，改完推 GitHub 即可，不用重装 hook。

不要把 `.env`、`notify.env` 提交到 GitHub。

## 部署 Render 服务

当前服务已按免费套餐部署，控制台：https://dashboard.render.com/web/srv-dacmps95efls73f07q20

新环境从零部署：

1. 用本仓库创建 Render **Web Service**，套餐选 **Free**。
2. Start Command：

```bash
python -u cursor_bot_server.py
```

3. 在 Render 填环境变量（不要提交这些值）：

| 变量 | 说明 |
|---|---|
| `FEISHU_APP_ID` | 飞书应用 ID |
| `FEISHU_APP_SECRET` | 飞书应用密钥 |
| `FEISHU_CHAT_ID` | 目标群 ID（`oc_` 开头） |
| `CURSOR_API_KEY` | Cursor API Key，用于 Cloud Agent 轮询 |
| `CURSOR_WEBHOOK_SECRET` | 本地 hook / webhook 共用密钥，建议不少于 32 位 |
| `POLL_INTERVAL` | 可选，默认 `30` |

仓库里的 `render.yaml`、`Procfile` 已按上述方式配置。推送到 `main` 后 Render 会自动部署。

4. 验证：

- https://cursor-robot.onrender.com/health 应返回 `"status": "ok"`
- https://cursor-robot.onrender.com/test 会往群里发一条测试卡片（无鉴权，仅排障时用）

飞书应用需要开通机器人能力、已发布，并且机器人已在目标群里。

免费套餐约 15 分钟无请求会休眠，唤醒大约 1 分钟。本地 hook 超时是 120 秒，一般仍能发出。

## 每台电脑安装本地 hook

安装包在 [`feishu_hook_installer/`](feishu_hook_installer/)。

1. 下载或拷贝整个 `feishu_hook_installer` 文件夹到目标电脑。
2. 复制 `notify.env.example` 为 `notify.env`，填入：

```
NOTIFY_URL=https://cursor-robot.onrender.com/local-notify
NOTIFY_TOKEN=<与 Render 的 CURSOR_WEBHOOK_SECRET 相同>
```

3. 双击 `install.cmd`。
4. 确认窗口里的 `computer` 是这台电脑的名字，且 `test result` 含 `"status":"sent"`。群里应出现测试卡片。
5. **完全退出** Cursor（托盘图标也退出）再打开。
6. 跑一次本地 Agent，结束后群里应有「本地 Cursor Agent 执行完成」卡片，并带这台机器名。

日志：`%USERPROFILE%\.cursor\hooks\notify-feishu.log`

Cursor 设置里搜索 Hooks，应能看到 `sessionStart` 和 `stop`。

## Cloud Agent

本地 hook 覆盖不了 Cloud Agent。从 Cursor 输入框选 **Cloud**，或打开 https://cursor.com/agents 启动。完成后由 Render 轮询发飞书。Webhook 文档：https://cursor.com/docs/cloud-agent/api/webhooks

## 以后改什么、要不要重装

| 要改的内容 | 改哪里 | 要不要重装 hook |
|---|---|---|
| 飞书卡片文案、完成/失败/需确认 | `cursor_bot_server.py`，推 GitHub | 否 |
| Cloud Agent 轮询 | 同上 | 否 |
| 飞书群 / 应用密钥 | Render 环境变量 | 否 |
| 本地 Agent 何时触发通知 | `feishu_hook_installer/` | 是，每台电脑再跑 `install.cmd` |
| hook 地址或密钥 | `notify.env` 与 Render 的 `CURSOR_WEBHOOK_SECRET` | 是 |
