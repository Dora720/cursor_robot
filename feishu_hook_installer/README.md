# 本地 Cursor Hook 安装包

把本文件夹拷到目标电脑后，按下面步骤安装。更完整的说明见仓库根目录 [README.md](../README.md)。

## 安装步骤

1. 复制 `notify.env.example` 为 `notify.env`，填写：

   ```
   NOTIFY_URL=https://你的服务.onrender.com/local-notify
   NOTIFY_TOKEN=<与 Render 的 CURSOR_WEBHOOK_SECRET 相同>
   ```

   `NOTIFY_URL` / `NOTIFY_TOKEN` 必须指向**用户自己部署**的服务与密钥（不能默认共用他人的，除非对方已分享）。

2. 双击 `install.cmd`。

3. 确认窗口里打印的 `computer` 是本机名称。

4. 飞书群应收到一条安装测试卡片；`test result` 含 `"status":"sent"`。

5. **完全退出** Cursor（托盘图标也退出）再打开，然后跑一次本地 Agent。

## 日志

`%USERPROFILE%\.cursor\hooks\notify-feishu.log`

## 更新后

hook 脚本有更新时，在本机再跑一次 `install.cmd`，并完全退出 Cursor 后重开。
