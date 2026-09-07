# Linux / Remote SSH Hook 安装包

用于 **Cursor Remote Explorer（Remote SSH）** 连到的 Linux 远程机。  
本机 Windows 仍用 [`feishu_hook_installer/`](../feishu_hook_installer/)。

远程 Agent 结束要通知飞书，必须在**远程 Linux 用户家目录**安装本包（不是只装本机）。

## 依赖

- `bash`、`curl`、`python3`

## 安装步骤（在远程 Linux 上执行）

1. 把整个 `feishu_hook_installer_linux` 目录拷到远程机（scp / rsync 均可）。
2. 复制并填写配置：

   ```bash
   cd feishu_hook_installer_linux
   cp notify.env.example notify.env
   # 编辑 notify.env：
   # NOTIFY_URL=https://cursor-robot.onrender.com/local-notify
   # NOTIFY_TOKEN=<与 Render 的 CURSOR_WEBHOOK_SECRET 相同>
   ```

3. 安装：

   ```bash
   bash install.sh
   ```

4. 安装成功时：
   - 终端里 `test result` 含 `HTTP:200` / `"status":"sent"`
   - 飞书群出现安装测试卡片（机器名为远程 hostname）

5. 在**本机**完全退出 Cursor（托盘也退）→ 再打开 → 用 Remote Explorer 重新连上该远程机。

6. 在远程工作区跑一轮 Agent，结束后群里应有完成卡片。

## 日志

远程机：

```text
~/.cursor/hooks/notify-feishu.log
```

## 与 Windows 版的差异

| 能力 | Windows 本机 | Linux Remote |
|------|--------------|--------------|
| Agent 结束通知 | 有 | 有 |
| 确认时机 | 飞书与 Agent 窗口**平级同时出现** | 同样平级：立刻 `ask` |
| 任一方确认即可继续 | 是（本机 UIA） | 是：远程发卡片/`ask`，**本机 Windows 的 confirm-bridge** 负责在飞书确认时点击 Agent 窗口 |
| Chat 名解析 | 可读本机 Cursor DB | 一般用工作区目录名 |

**重要：** Remote Explorer 时 Agent 窗口在本机 IDE 上。要「飞书或 Agent 任一端确认即可」，请：

1. 远程 Linux 安装本目录（`bash install.sh`）
2. **本机 Windows 也安装** [`feishu_hook_installer`](../feishu_hook_installer/)（会启动 `confirm-bridge`）

Remote SSH 下 hooks 仍可能受 Cursor 版本影响；若装完仍无通知，先看远程日志有没有 `hook start`，再在本机 Settings → Hooks / Output → Hooks 排查。

## 更新

远程机再执行一次 `bash install.sh`，然后本机完全退出 Cursor 并重连 Remote。

## 卸载

```bash
bash uninstall.sh
```

然后本机完全退出 Cursor，再重连 Remote。
