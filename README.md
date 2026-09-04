# cursor_robot

Cursor Agent 完成后或需要确认时，通过飞书应用机器人往指定群发卡片。卡片含 Chat 名称；可在飞书点「确认 / 拒绝」，也可回复卡片或 `@机器人 发送 <Chat名> 内容` 把消息发回对应 Chat。

- 作者示例服务：https://cursor-robot.onrender.com（用户需换成自己的）
- 仓库：https://github.com/Dora720/cursor_robot

## 它做什么

1. **本地 Agent**：每台电脑安装 Cursor hook。结束时通知飞书；执行命令前可在飞书确认；飞书回复会在下一轮 Agent 作为 followup 注入。
2. **Cloud Agent**：Render 轮询完成 / 失败 / 需要确认；飞书确认会调用 Cursor followup / stop；飞书发的文字会立刻 followup。

本地 Agent 的事件只存在于那台电脑，所以每台要跑本地 Agent 的机器都要装一次 hook。只改飞书文案或 Cloud Agent 逻辑时推 GitHub 即可；改本地何时确认 / 注入消息时要重装 hook。

不要把 `.env`、`notify.env` 提交到 GitHub。

## 用户拿到代码要做什么

**用户不能直接用仓库作者已部署好的 Render 或飞书应用。** 代码可以共用，账号、密钥、群、服务地址必须各自准备一套（除非对方把 Render 权限、飞书应用和密钥都分享给你）。

用户拿到本仓库后，请按下面顺序自建：

1. **自己部署后端**（推荐 Render Free，或其他能跑 Python 的主机）  
   - 用本仓库创建 Web Service，Start Command：`python -u cursor_bot_server.py`  
   - 记下你的公网地址，例如 `https://你的服务.onrender.com`
2. **自己创建并配置飞书应用机器人**（见下一节「设置飞书机器人」）
3. **在 Render（或你的主机）填写自己的环境变量**（不要提交到 Git）

| 变量 | 说明 |
|---|---|
| `FEISHU_APP_ID` | 你的飞书应用 ID |
| `FEISHU_APP_SECRET` | 你的飞书应用密钥 |
| `FEISHU_CHAT_ID` | 你的目标群 ID（`oc_` 开头） |
| `CURSOR_API_KEY` | 你的 Cursor API Key（仅 Cloud Agent 需要） |
| `CURSOR_WEBHOOK_SECRET` | **自己生成**的共享密钥，建议 ≥32 位；不是 Cursor 控制台下发的固定值 |
| `POLL_INTERVAL` | 可选，默认 `30` |
| `FEISHU_VERIFICATION_TOKEN` | 可选，与飞书「Verification Token」一致 |

`CURSOR_WEBHOOK_SECRET` 用密码生成器或随机字符串即可。本地 hook 的 `NOTIFY_TOKEN` **必须与它相同**。

4. **每台要用本地 Agent 的电脑安装 hook**  
   - 拷贝 `feishu_hook_installer/`  
   - `notify.env` 里 `NOTIFY_URL` 指向**你自己的**服务：`https://你的服务.onrender.com/local-notify`  
   - `NOTIFY_TOKEN` = 你的 `CURSOR_WEBHOOK_SECRET`  
   - 跑 `install.cmd`，再**完全退出** Cursor 后重开  

验证：打开 `https://你的服务.onrender.com/health` 应返回 `"status": "ok"`；`/test` 会往你的群发一条测试卡片。

上面 README 里出现的 `https://cursor-robot.onrender.com` 只是作者当前示例部署，**用户请全部换成自己的地址**。

## 设置飞书机器人

在 [飞书开放平台](https://open.feishu.cn/) 创建企业自建应用，按下面配置。后端公网地址请换成你自己的（下文用 `https://你的服务.onrender.com` 举例）。

### 1. 创建应用并开通机器人

1. 进入 [开发者后台](https://open.feishu.cn/app) → **创建企业自建应用**。
2. 打开应用 → **添加应用能力** → 启用 **机器人**。
3. 在 **凭证与基础信息** 中复制：
   - `App ID` → 填到环境变量 `FEISHU_APP_ID`
   - `App Secret` → 填到环境变量 `FEISHU_APP_SECRET`（不要提交到 Git）

### 2. 申请权限

在 **权限管理** 中至少申请：

- 以应用身份发消息（如 `im:message` 或 `im:message:send_as_bot`）
- **接收群聊中 @机器人 消息**（至少要有，否则点确认 / 回复可能收不到）
- 若希望群里不 @ 也能把回复送进 Cursor，再申请 **读取群组中所有消息**（或平台上对应的群消息权限）

改权限后必须 **创建版本并发布**，权限才会生效。

### 3. 把机器人拉进目标群

1. 打开目标飞书群 → **设置** → **群机器人** → **添加机器人**，选中该应用。
2. 记下该群的 `chat_id`（`oc_` 开头），填到环境变量 `FEISHU_CHAT_ID`。  
   不确定时可在应用已有发消息权限后，用 tenant token 调  
   `GET https://open.feishu.cn/open-apis/im/v1/chats`  
   在返回列表里找对应群的 `chat_id`。

### 4. 配置事件与回调

服务必须已部署且公网可访问，再配回调（Encrypt Key 可留空，除非你自行做加密）。

1. 打开应用 → **事件与回调**。
2. **请求网址** 填：`https://你的服务.onrender.com/feishu-callback`  
   保存时飞书会发 `url_verification`；服务需返回 `challenge`（本仓库已支持）。
3. 订阅回调 / 事件（名称以控制台为准）：
   - `card.action.trigger`（卡片按钮：确认 / 拒绝）
   - `im.message.receive_v1`（群消息，用于把飞书文字发回 Chat）
4. 若控制台仍有旧版「消息卡片请求网址」，可填同一 URL。
5. 可选：把开放平台里的 **Verification Token** 填到环境变量 `FEISHU_VERIFICATION_TOKEN`。
6. **创建版本并发布**，否则线上群用的还是旧配置。

### 5. 验证飞书是否通

1. 环境变量已写入 Render（或本地 `.env`）后，打开：  
   `https://你的服务.onrender.com/test`  
   目标群应收到一条测试卡片。
2. 在确认卡片上点「确认 / 拒绝」，卡片标题颜色应更新（待确认=橙，确认=绿，拒绝=红等）。
3. 在群里 **@机器人** 回复卡片，或发送：  
   `@机器人 发送 <Chat名> 你的内容`  
   （若只开了「收 @」，不 @ 则飞书不会推事件。）

飞书把话发回 **本地** Chat 时：先在服务端排队，再在该 Chat 下一轮 Agent 的 `stop` 时用 `followup_message` 注入。Agent 已结束的话，在同一 Chat 里再发一条任意消息即可。Cloud Agent 会立刻 followup。

## 部署 Render 服务

作者当前示例服务（仅供参考）：https://dashboard.render.com/web/srv-dacmps95efls73f07q20  
示例地址：https://cursor-robot.onrender.com

新环境从零部署步骤与「用户拿到代码要做什么」相同。仓库里的 `render.yaml`、`Procfile` 已写好启动方式；连上你自己的 GitHub 仓库并推送到 `main` 后，Render 可自动部署。

部署后验证（把域名换成你的）：

- `https://你的服务.onrender.com/health` → `"status": "ok"`
- `https://你的服务.onrender.com/test` → 往群发测试卡片（无鉴权，仅排障）

飞书回调请求网址示例：`https://你的服务.onrender.com/feishu-callback`

免费套餐约 15 分钟无请求会休眠，唤醒大约 1 分钟。本地 hook 超时是 120 秒，一般仍能发出。本机若还是旧 hook（没有 followup take），飞书回复进不了 Cursor，需再跑一次 `install.cmd`。

## 每台电脑安装本地 hook

安装包在 [`feishu_hook_installer/`](feishu_hook_installer/)，也可先看该目录下的 [README.md](feishu_hook_installer/README.md)。

1. 下载或拷贝整个 `feishu_hook_installer` 文件夹到目标电脑。
2. 复制 `notify.env.example` 为 `notify.env`，填入：

```
NOTIFY_URL=https://你的服务.onrender.com/local-notify
NOTIFY_TOKEN=<与你的 Render CURSOR_WEBHOOK_SECRET 相同>
```

（若用户加入的是作者已分享密钥的同一套服务，才可使用作者的示例域名；默认请填自己的。）
3. 双击 `install.cmd`。
4. 确认窗口里的 `computer` 是这台电脑的名字，且 `test result` 含 `"status":"sent"`。群里应出现测试卡片。
5. **完全退出** Cursor（托盘图标也退出）再打开。
6. 跑一次本地 Agent，结束后群里应有「本地 Cursor Agent 执行完成」卡片，并带这台机器名。

日志：`%USERPROFILE%\.cursor\hooks\notify-feishu.log`

Cursor 设置里搜索 Hooks，应能看到 `sessionStart`、`stop`、`beforeShellExecution`。

本功能更新了 hook，**已安装过的电脑需要再跑一次 `install.cmd`**。

本地需要确认时：**飞书** 与 **Cursor Agent 窗口** 平级同时出现，**先点的生效**（先到先生效）。
- 任一方确认/拒绝后，另一端再操作会被忽略；飞书卡片会变成「已处理，无需再点」
- 若在 **Cursor Agent 窗口**先操作，飞书原确认卡片会自动更新为「已在 Cursor 处理」
- 无系统弹窗；也不用等飞书超时才出现 Agent 确认

已装过的电脑请再跑一次 `install.cmd`，并完全退出 Cursor 后重开。
