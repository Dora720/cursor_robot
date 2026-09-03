"""
Cursor 状态通知飞书机器人服务
功能：
1. 接收 Cursor webhook（FINISHED / ERROR 状态）
2. 定时轮询 Cursor API，检测"需要确认"状态并推送
3. 发送交互卡片消息到飞书群
（交互功能预留：飞书长连接事件处理后续扩展）
"""

import json
import time
import hmac
import hashlib
import threading
import os
import requests
from flask import Flask, request, jsonify


def _load_dotenv(path=".env"):
    """Load KEY=VALUE pairs from a local .env file without overriding existing env vars."""
    if not os.path.isfile(path):
        return
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, _, value = line.partition("=")
            key = key.strip()
            value = value.strip().strip('"').strip("'")
            os.environ.setdefault(key, value)


_load_dotenv()

# ====================== Config (from environment) ======================
FEISHU_APP_ID = os.environ.get("FEISHU_APP_ID", "")
FEISHU_APP_SECRET = os.environ.get("FEISHU_APP_SECRET", "")
FEISHU_CHAT_ID = os.environ.get("FEISHU_CHAT_ID", "")
CURSOR_API_KEY = os.environ.get("CURSOR_API_KEY", "")
CURSOR_WEBHOOK_SECRET = os.environ.get("CURSOR_WEBHOOK_SECRET", "")
POLL_INTERVAL = int(os.environ.get("POLL_INTERVAL", "30"))
# ======================================================================

app = Flask(__name__)

# token 缓存
_token_cache = {"token": None, "expire_at": 0}

# 已知的 agent 状态缓存（避免重复通知）
agent_status_cache = {}


# ====================== 飞书 API 封装 ======================
def get_tenant_access_token():
    """获取并缓存 tenant_access_token"""
    if _token_cache["token"] and time.time() < _token_cache["expire_at"] - 60:
        return _token_cache["token"]

    resp = requests.post(
        "https://open.feishu.cn/open-apis/auth/v3/tenant_access_token/internal",
        json={"app_id": FEISHU_APP_ID, "app_secret": FEISHU_APP_SECRET},
        timeout=10
    )
    data = resp.json()
    if data.get("code") != 0:
        raise Exception(f"获取token失败: {data}")

    _token_cache["token"] = data["tenant_access_token"]
    _token_cache["expire_at"] = time.time() + data.get("expire", 7200)
    return _token_cache["token"]


def send_card_to_chat(card_content):
    """发送交互卡片到指定群"""
    token = get_tenant_access_token()
    resp = requests.post(
        "https://open.feishu.cn/open-apis/im/v1/messages?receive_id_type=chat_id",
        headers={
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/json"
        },
        json={
            "receive_id": FEISHU_CHAT_ID,
            "msg_type": "interactive",
            "content": json.dumps(card_content)
        },
        timeout=10
    )
    result = resp.json()
    if result.get("code") != 0:
        print(f"[飞书] 发送消息失败: {result}")
    else:
        print(f"[飞书] 消息发送成功, message_id={result['data']['message_id']}")
    return result


def build_cursor_card(payload, status_label=None):
    """构建飞书交互卡片"""
    status = payload.get("status", "UNKNOWN")
    summary = payload.get("summary", "无摘要")
    agent_id = payload.get("id", "未知")
    target = payload.get("target", {})
    source = payload.get("source", {})

    status_map = {
        "FINISHED": ("✅ Cursor Agent 执行完成", "green"),
        "ERROR": ("❌ Cursor Agent 执行出错", "red"),
        "NEEDS_CONFIRMATION": ("⚠️ Cursor Agent 需要确认", "orange"),
        "RUNNING": ("🔄 Cursor Agent 运行中", "blue"),
    }
    title, color = status_map.get(status, (f"🔔 Cursor Agent: {status_label or status}", "blue"))

    elements = [
        {"tag": "div", "text": {"tag": "lark_md",
            "content": f"**Agent ID:** `{agent_id}`\n**状态:** `{status_label or status}`\n**摘要:** {summary}"}},
        {"tag": "div", "text": {"tag": "lark_md",
            "content": f"**仓库:** {source.get('repository', 'N/A')}\n**分支:** `{source.get('ref', 'N/A')}`"}},
    ]

    actions = []
    if target.get("prUrl"):
        actions.append({"tag": "button", "text": {"tag": "plain_text", "content": "查看 PR"},
            "url": target["prUrl"], "type": "primary"})
    if target.get("url"):
        actions.append({"tag": "button", "text": {"tag": "plain_text", "content": "Agent 详情"},
            "url": target["url"], "type": "default"})

    # 需要确认时，添加"去确认"按钮
    if status == "NEEDS_CONFIRMATION" and target.get("url"):
        actions.append({"tag": "button", "text": {"tag": "plain_text", "content": "去确认"},
            "url": target["url"], "type": "primary"})

    if actions:
        elements.append({"tag": "action", "actions": actions})

    return {
        "config": {"wide_screen_mode": True},
        "header": {"title": {"tag": "plain_text", "content": title}, "template": color},
        "elements": elements
    }


# ====================== 1. Cursor Webhook 接收 ======================
@app.route("/cursor-webhook", methods=["POST"])
def cursor_webhook():
    raw_body = request.get_data()
    signature = request.headers.get("X-Webhook-Signature", "")

    # 签名校验
    if CURSOR_WEBHOOK_SECRET:
        expected = 'sha256=' + hmac.new(
            CURSOR_WEBHOOK_SECRET.encode(), raw_body, hashlib.sha256
        ).hexdigest()
        if not hmac.compare_digest(expected, signature):
            return jsonify({"error": "Invalid signature"}), 403

    payload = json.loads(raw_body)
    event_type = payload.get("event")

    if event_type != "statusChange":
        return jsonify({"status": "ignored"}), 200

    agent_id = payload.get("id")
    status = payload.get("status")

    # 更新缓存，避免轮询重复通知
    agent_status_cache[agent_id] = status

    print(f"[Webhook] 收到状态变更: agent={agent_id}, status={status}")

    card = build_cursor_card(payload)
    send_card_to_chat(card)

    return jsonify({"status": "sent"}), 200


# ====================== Local IDE Agent notify (Cursor hooks on each machine) ======================
@app.route("/local-notify", methods=["POST"])
def local_notify():
    """Receive completion events from a per-machine Cursor stop hook."""
    token = request.headers.get("X-Notify-Token", "")
    secret = CURSOR_WEBHOOK_SECRET or ""
    if not secret or len(token) != len(secret) or not hmac.compare_digest(token, secret):
        return jsonify({"error": "unauthorized"}), 403

    payload = request.get_json(silent=True) or {}
    raw_status = str(payload.get("status", "FINISHED")).upper()
    status_map = {
        "COMPLETED": "FINISHED",
        "FINISHED": "FINISHED",
        "ERROR": "ERROR",
        "FAILED": "ERROR",
    }
    status = status_map.get(raw_status)
    if not status:
        return jsonify({"status": "ignored", "reason": raw_status}), 200

    agent_id = payload.get("id") or payload.get("conversation_id") or "local-agent"
    summary = payload.get("summary") or payload.get("model") or "本地 Cursor Agent 执行完成"
    workspace = payload.get("workspace") or ""
    if isinstance(payload.get("workspace_roots"), list) and payload["workspace_roots"]:
        workspace = payload["workspace_roots"][0]
    machine = payload.get("machine") or ""

    card_payload = {
        "id": agent_id,
        "status": status,
        "summary": summary if not machine else f"{summary}\n**机器:** {machine}",
        "source": {"repository": workspace or "local", "ref": payload.get("ref", "")},
        "target": {"url": payload.get("url", "https://cursor.com")}
    }
    print(f"[Local] 收到本地 Agent 通知: agent={agent_id}, status={status}")
    card = build_cursor_card(card_payload)
    send_card_to_chat(card)
    return jsonify({"status": "sent"}), 200


# ====================== 2. Cursor API 轮询（检测需要确认） ======================
def poll_cursor_agents():
    """定时轮询 Cursor agent 列表，检测需要确认的状态"""
    print(f"[轮询] 启动 Cursor agent 状态轮询，间隔 {POLL_INTERVAL}s")

    while True:
        try:
            headers = {
                "Authorization": f"Bearer {CURSOR_API_KEY}",
                "Content-Type": "application/json"
            }

            # 查询 agent 列表（Cursor Background Agents API）
            resp = requests.get(
                "https://api.cursor.com/v1/agents",
                headers=headers,
                timeout=10
            )

            if resp.status_code != 200:
                print(f"[轮询] 查询失败: {resp.status_code} {resp.text}")
                time.sleep(POLL_INTERVAL)
                continue

            data = resp.json()
            agents = data.get("items", data.get("agents", data.get("data", [])))

            for agent in agents:
                agent_id = agent.get("id")
                status = str(agent.get("status", "")).upper()
                prev_status = agent_status_cache.get(agent_id)

                # 检测"需要确认"状态（兼容多种写法）
                needs_confirmation = any(keyword in status for keyword in
                    ["NEEDS_CONFIRMATION", "WAITING_CONFIRMATION", "PENDING_CONFIRMATION",
                     "AWAITING_INPUT", "NEEDS_INPUT", "BLOCKED"])

                if prev_status is None:
                    # First sighting: remember status only, do not notify historical agents.
                    agent_status_cache[agent_id] = (
                        "NEEDS_CONFIRMATION" if needs_confirmation else status
                    )
                    continue

                if needs_confirmation and prev_status != "NEEDS_CONFIRMATION":
                    print(f"[轮询] 检测到需要确认: agent={agent_id}, status={status}")
                    agent_status_cache[agent_id] = "NEEDS_CONFIRMATION"

                    payload = {
                        "id": agent_id,
                        "status": "NEEDS_CONFIRMATION",
                        "summary": agent.get("summary", agent.get("task", "Agent 需要您的确认")),
                        "source": agent.get("source", {}),
                        "target": {
                            "url": agent.get("url", f"https://cursor.com/agents?id={agent_id}"),
                            "prUrl": agent.get("prUrl", agent.get("pr_url", ""))
                        }
                    }
                    card = build_cursor_card(payload, status_label="需要确认")
                    send_card_to_chat(card)

                elif status in ["FINISHED", "ERROR"] and prev_status != status:
                    # Fallback when Cursor does not send a webhook (e.g. agents started from the UI).
                    print(f"[轮询] 检测到完成/错误: agent={agent_id}, status={status}")
                    agent_status_cache[agent_id] = status
                    payload = {
                        "id": agent_id,
                        "status": status,
                        "summary": agent.get("summary", agent.get("task", f"Agent 状态: {status}")),
                        "source": agent.get("source", {}),
                        "target": {
                            "url": agent.get("url", f"https://cursor.com/agents?id={agent_id}"),
                            "prUrl": agent.get("prUrl", agent.get("pr_url", ""))
                        }
                    }
                    card = build_cursor_card(payload)
                    send_card_to_chat(card)

                elif status != prev_status and not needs_confirmation:
                    agent_status_cache[agent_id] = status

        except Exception as e:
            print(f"[轮询] 异常: {e}")

        time.sleep(POLL_INTERVAL)


# ====================== 健康检查 ======================
@app.route("/health", methods=["GET"])
def health():
    return jsonify({
        "status": "ok",
        "polling": "running",
        "monitored_agents": len(agent_status_cache),
        "chat_id": FEISHU_CHAT_ID
    })


# ====================== 测试接口（发送测试消息） ======================
@app.route("/test", methods=["GET"])
def test_message():
    """发送一条测试消息到群里"""
    test_payload = {
        "id": "bc_test001",
        "status": "FINISHED",
        "summary": "测试消息：机器人已成功上线！",
        "source": {"repository": "测试仓库", "ref": "main"},
        "target": {"url": "https://cursor.com"}
    }
    card = build_cursor_card(test_payload)
    result = send_card_to_chat(card)
    return jsonify({"status": "sent", "success": result.get("code") == 0})


# ====================== 主入口 ======================
if __name__ == "__main__":
    print("=" * 50)
    print("Cursor 飞书通知机器人启动中...")
    print(f"目标群: Dora的牛马群 ({FEISHU_CHAT_ID})")
    print(f"轮询间隔: {POLL_INTERVAL}s")
    print("=" * 50)

    # 启动 Cursor 轮询（后台线程）
    poll_thread = threading.Thread(target=poll_cursor_agents, daemon=True)
    poll_thread.start()
    time.sleep(1)

    # 启动 HTTP 服务（Render 会通过 $PORT 环境变量指定端口）
    port = int(os.environ.get("PORT", 5000))
    print(f"[HTTP] 服务启动，监听 0.0.0.0:{port}")
    print("[HTTP] Webhook地址: https://<你的render域名>/cursor-webhook")
    app.run(host="0.0.0.0", port=port)
