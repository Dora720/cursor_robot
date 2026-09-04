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
import uuid
import re
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
FEISHU_VERIFICATION_TOKEN = os.environ.get("FEISHU_VERIFICATION_TOKEN", "")
# ======================================================================

app = Flask(__name__)

# token 缓存
_token_cache = {"token": None, "expire_at": 0}

# 已知的 agent 状态缓存（避免重复通知）
agent_status_cache = {}

# In-memory stores for Feishu confirm / follow-up (lost on process restart).
_store_lock = threading.Lock()
chat_registry = {}          # conversation_id -> meta
pending_confirms = {}       # confirm_id -> record
pending_followups = {}      # conversation_id -> [text, ...]
feishu_msg_to_chat = {}     # feishu message_id -> conversation_id
last_active_chat = {"id": ""}
# conversation_id -> unix expiry; recent Feishu allow skips another card
auto_allow_until = {}


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


def send_text_to_chat(text, reply_to_message_id=""):
    """Send a plain text message to the Feishu group (optional reply)."""
    token = get_tenant_access_token()
    content = json.dumps({"text": text}, ensure_ascii=False)
    if reply_to_message_id:
        resp = requests.post(
            f"https://open.feishu.cn/open-apis/im/v1/messages/{reply_to_message_id}/reply",
            headers={
                "Authorization": f"Bearer {token}",
                "Content-Type": "application/json",
            },
            json={"msg_type": "text", "content": content},
            timeout=10,
        )
    else:
        resp = requests.post(
            "https://open.feishu.cn/open-apis/im/v1/messages?receive_id_type=chat_id",
            headers={
                "Authorization": f"Bearer {token}",
                "Content-Type": "application/json",
            },
            json={
                "receive_id": FEISHU_CHAT_ID,
                "msg_type": "text",
                "content": content,
            },
            timeout=10,
        )
    try:
        return resp.json()
    except Exception:
        return {"code": -1, "msg": resp.text[:200]}


def send_card_to_chat(card_content):
    """发送交互卡片到指定群"""
    token = get_tenant_access_token()
    conv_id = card_content.get("_conversation_id") or ""
    confirm_id = card_content.get("_confirm_id") or ""
    public_card = {k: v for k, v in card_content.items() if not str(k).startswith("_")}
    resp = requests.post(
        "https://open.feishu.cn/open-apis/im/v1/messages?receive_id_type=chat_id",
        headers={
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/json"
        },
        json={
            "receive_id": FEISHU_CHAT_ID,
            "msg_type": "interactive",
            "content": json.dumps(public_card)
        },
        timeout=10
    )
    result = resp.json()
    if result.get("code") != 0:
        print(f"[飞书] 发送消息失败: {result}", flush=True)
    else:
        print(f"[飞书] 消息发送成功, message_id={result['data']['message_id']}", flush=True)
        msg_id = result["data"].get("message_id")
        if msg_id and conv_id:
            with _store_lock:
                feishu_msg_to_chat[msg_id] = conv_id
                if confirm_id and confirm_id in pending_confirms:
                    pending_confirms[confirm_id]["message_id"] = msg_id
    return result


def patch_card_message(message_id, card_content):
    """Update an already-sent interactive card (shared card / update_multi)."""
    if not message_id:
        return {"code": -1, "msg": "missing message_id"}
    token = get_tenant_access_token()
    public_card = {k: v for k, v in (card_content or {}).items() if not str(k).startswith("_")}
    if "config" not in public_card:
        public_card["config"] = {"wide_screen_mode": True, "update_multi": True}
    else:
        public_card["config"] = dict(public_card.get("config") or {})
        public_card["config"]["update_multi"] = True
    resp = requests.patch(
        f"https://open.feishu.cn/open-apis/im/v1/messages/{message_id}",
        headers={
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/json",
        },
        json={"content": json.dumps(public_card, ensure_ascii=False)},
        timeout=10,
    )
    try:
        result = resp.json()
    except Exception:
        return {"code": -1, "msg": resp.text[:200]}
    if result.get("code") != 0:
        print(f"[飞书] 更新卡片失败: {result}", flush=True)
    else:
        print(f"[飞书] 卡片已更新 message_id={message_id}", flush=True)
    return result


def notify_confirm_resolved(confirm_id, decision, source=""):
    """After Agent-window (or other) resolve, update Feishu card so the group sees it."""
    with _store_lock:
        rec = pending_confirms.get(confirm_id) or {}
        message_id = rec.get("message_id") or ""
    if not message_id:
        # Fallback: plain text in group if we lost the card id.
        tip = {
            "allow": "已在 Cursor Agent 窗口确认，可继续。",
            "deny": "已在 Cursor Agent 窗口拒绝。",
            "cursor": "已在 Cursor Agent 窗口处理，无需再点飞书。",
        }.get(decision, "确认状态已更新。")
        if source:
            tip = f"{tip}（来源：{source}）"
        send_text_to_chat(tip)
        return
    card = _confirm_result_card(confirm_id, decision, applied=True, existing="")
    # For cursor-handled case, prefer the "already in Agent" wording.
    if decision == "cursor" or source in ("agent_window", "cursor"):
        card = _confirm_result_card(confirm_id, decision, applied=False, existing="cursor")
    patch_card_message(message_id, card)


def _notify_token_ok(token):
    secret = CURSOR_WEBHOOK_SECRET or ""
    token = token or ""
    return bool(secret) and len(token) == len(secret) and hmac.compare_digest(token, secret)


def _register_chat(conversation_id, **meta):
    if not conversation_id:
        return
    with _store_lock:
        row = chat_registry.get(conversation_id, {})
        row.update({k: v for k, v in meta.items() if v})
        row["last_seen"] = time.time()
        chat_registry[conversation_id] = row
        last_active_chat["id"] = conversation_id


def _normalize_workspace(workspace):
    workspace = str(workspace or "")
    if workspace.startswith("/") and len(workspace) > 2 and workspace[2] == ":":
        workspace = workspace[1:]
    return workspace


def _chat_name_from(payload, workspace=""):
    name = (
        payload.get("chat_name")
        or payload.get("conversation_title")
        or payload.get("title")
        or payload.get("name")
        or ""
    )
    if not name and workspace:
        name = os.path.basename(workspace.replace("\\", "/").rstrip("/"))
    return name or ""


def cursor_api_headers():
    return {
        "Authorization": f"Bearer {CURSOR_API_KEY}",
        "Content-Type": "application/json",
    }


def cursor_followup(agent_id, text):
    """Send a follow-up prompt to a Cloud Agent."""
    resp = requests.post(
        f"https://api.cursor.com/v1/agents/{agent_id}/runs",
        headers=cursor_api_headers(),
        json={"prompt": {"text": text}},
        timeout=20,
    )
    try:
        return resp.status_code, resp.json()
    except Exception:
        return resp.status_code, {"raw": resp.text[:300]}


def cursor_stop_agent(agent_id):
    """Best-effort stop/cancel for a Cloud Agent."""
    for method, url in (
        ("POST", f"https://api.cursor.com/v1/agents/{agent_id}/stop"),
        ("POST", f"https://api.cursor.com/v0/agents/{agent_id}/stop"),
    ):
        try:
            resp = requests.request(method, url, headers=cursor_api_headers(), timeout=15)
            if resp.status_code < 400:
                return resp.status_code, resp.json() if resp.text else {}
        except Exception as exc:
            print(f"[Cursor] stop {url} failed: {exc}", flush=True)
    return 0, {}


def enqueue_followup(conversation_id, text, kind="local"):
    text = (text or "").strip()
    if not conversation_id or not text:
        return False
    if kind == "cloud":
        status, data = cursor_followup(conversation_id, text)
        print(f"[Followup] cloud {conversation_id} http={status} {data}", flush=True)
        return 200 <= status < 300
    with _store_lock:
        pending_followups.setdefault(conversation_id, []).append(text)
    print(f"[Followup] queued local {conversation_id}: {text[:80]}", flush=True)
    return True


def build_cursor_card(payload, status_label=None):
    """构建飞书交互卡片"""
    status = payload.get("status", "UNKNOWN")
    summary = payload.get("summary", "无摘要")
    agent_id = payload.get("id", "未知")
    target = payload.get("target", {})
    source = payload.get("source", {})
    chat_name = payload.get("chat_name") or payload.get("name") or ""
    confirm_id = payload.get("confirm_id") or ""
    kind = payload.get("kind") or ""

    status_map = {
        "FINISHED": ("✅ Cursor Agent 执行完成", "green"),
        "ERROR": ("❌ Cursor Agent 执行出错", "red"),
        "NEEDS_CONFIRMATION": ("⚠️ Cursor Agent 需要确认", "orange"),
        "RUNNING": ("🔄 Cursor Agent 运行中", "blue"),
    }
    title, color = status_map.get(status, (f"🔔 Cursor Agent: {status_label or status}", "blue"))

    info_lines = [
        f"**Agent ID:** `{agent_id}`",
        f"**状态:** `{status_label or status}`",
    ]
    if chat_name:
        info_lines.append(f"**Chat:** {chat_name}")
    info_lines.append(f"**摘要:** {summary}")

    elements = [
        {"tag": "div", "text": {"tag": "lark_md", "content": "\n".join(info_lines)}},
        {"tag": "div", "text": {"tag": "lark_md",
            "content": f"**仓库:** {source.get('repository', 'N/A')}\n**分支:** `{source.get('ref', 'N/A')}`"}},
        {"tag": "div", "text": {"tag": "lark_md",
            "content": (
                f"确认方式（平级二选一）：飞书按钮 或 Cursor Agent 窗口，**先点的生效**，另一端再点无效。\n"
                f"向该 Chat 发消息：回复本卡片并 @机器人，或 `@机器人 发送 {chat_name or agent_id} 你的内容`"
            )}},
    ]

    actions = []
    if confirm_id:
        actions.append({
            "tag": "button",
            "text": {"tag": "plain_text", "content": "确认"},
            "type": "primary",
            "value": {"action": "confirm", "confirm_id": confirm_id, "kind": kind or "local", "id": agent_id},
        })
        actions.append({
            "tag": "button",
            "text": {"tag": "plain_text", "content": "拒绝"},
            "type": "default",
            "value": {"action": "deny", "confirm_id": confirm_id, "kind": kind or "local", "id": agent_id},
        })
    if target.get("prUrl"):
        actions.append({"tag": "button", "text": {"tag": "plain_text", "content": "查看 PR"},
            "url": target["prUrl"], "type": "primary"})
    if target.get("url"):
        actions.append({"tag": "button", "text": {"tag": "plain_text", "content": "Agent 详情"},
            "url": target["url"], "type": "default"})
    if status == "NEEDS_CONFIRMATION" and target.get("url") and not confirm_id:
        actions.append({"tag": "button", "text": {"tag": "plain_text", "content": "去确认"},
            "url": target["url"], "type": "primary"})

    if actions:
        elements.append({"tag": "action", "actions": actions})

    card = {
        "config": {"wide_screen_mode": True, "update_multi": True},
        "header": {"title": {"tag": "plain_text", "content": title}, "template": color},
        "elements": elements,
        "_conversation_id": agent_id,
    }
    return card


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
    payload["chat_name"] = _chat_name_from(payload)
    payload["kind"] = "cloud"
    _register_chat(agent_id, name=payload.get("chat_name"), kind="cloud")

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
    workspace = payload.get("workspace") or ""
    if isinstance(payload.get("workspace_roots"), list) and payload["workspace_roots"]:
        workspace = payload["workspace_roots"][0]
    workspace = _normalize_workspace(workspace)
    machine = payload.get("machine") or ""
    model = payload.get("model") or ""
    chat_name = _chat_name_from(payload, workspace)
    _register_chat(agent_id, name=chat_name, machine=machine, kind="local", workspace=workspace)
    # Always compose Chinese on the server. Windows PowerShell hooks often
    # send GBK-mojibake in the summary field.
    summary = "本地 Cursor Agent 执行完成"
    if model:
        summary = f"本地 Cursor Agent 执行完成 ({model})"
    if machine:
        summary = f"{summary}\n**机器:** {machine}"

    card_payload = {
        "id": agent_id,
        "status": status,
        "chat_name": chat_name,
        "kind": "local",
        "summary": summary,
        "source": {"repository": workspace or "local", "ref": payload.get("ref", "")},
        "target": {"url": payload.get("url", "https://cursor.com")}
    }
    print(f"[Local] 收到本地 Agent 通知: agent={agent_id}, status={status}, machine={machine}", flush=True)
    card = build_cursor_card(card_payload)
    result = send_card_to_chat(card)
    feishu_ok = result.get("code") == 0
    return jsonify({
        "status": "sent" if feishu_ok else "feishu_error",
        "feishu_code": result.get("code"),
        "feishu_msg": result.get("msg"),
        "chat_name": chat_name,
    }), 200


@app.route("/local-confirm/request", methods=["POST"])
def local_confirm_request():
    """Local hook asks Feishu to approve a tool/shell command."""
    if not _notify_token_ok(request.headers.get("X-Notify-Token", "")):
        return jsonify({"error": "unauthorized"}), 403
    payload = request.get_json(silent=True) or {}
    conversation_id = payload.get("conversation_id") or payload.get("id") or "local-agent"
    workspace = _normalize_workspace(payload.get("workspace") or "")
    chat_name = _chat_name_from(payload, workspace)
    machine = payload.get("machine") or ""
    detail = payload.get("detail") or payload.get("command") or payload.get("tool") or "需要确认的操作"
    _register_chat(conversation_id, name=chat_name, machine=machine, kind="local", workspace=workspace)

    with _store_lock:
        until = auto_allow_until.get(conversation_id) or 0
        if until > time.time():
            confirm_id = uuid.uuid4().hex[:16]
            pending_confirms[confirm_id] = {
                "status": "allow",
                "conversation_id": conversation_id,
                "kind": "local",
                "detail": detail,
                "created": time.time(),
            }
            return jsonify({"confirm_id": confirm_id, "status": "allow", "auto_allow": True})

    confirm_id = uuid.uuid4().hex[:16]
    with _store_lock:
        pending_confirms[confirm_id] = {
            "status": "pending",
            "conversation_id": conversation_id,
            "kind": "local",
            "detail": detail,
            "created": time.time(),
            "message_id": "",
        }
    card = build_cursor_card({
        "id": conversation_id,
        "status": "NEEDS_CONFIRMATION",
        "chat_name": chat_name,
        "confirm_id": confirm_id,
        "kind": "local",
        "summary": f"{machine + ' / ' if machine else ''}{detail}",
        "source": {"repository": workspace or "local", "ref": ""},
        "target": {},
    }, status_label="需要确认")
    card["_confirm_id"] = confirm_id
    send_card_to_chat(card)
    return jsonify({"confirm_id": confirm_id, "status": "pending", "auto_allow": False})


@app.route("/local-confirm/status/<confirm_id>", methods=["GET"])
def local_confirm_status(confirm_id):
    if not _notify_token_ok(request.headers.get("X-Notify-Token", "")):
        return jsonify({"error": "unauthorized"}), 403
    with _store_lock:
        rec = pending_confirms.get(confirm_id)
    if not rec:
        return jsonify({"status": "unknown"}), 404
    if time.time() - rec.get("created", 0) > 180 and rec.get("status") == "pending":
        rec["status"] = "timeout"
    return jsonify({"status": rec.get("status"), "conversation_id": rec.get("conversation_id")})


@app.route("/local-confirm/decide", methods=["POST"])
def local_confirm_decide():
    """Record allow/deny from Feishu, local client, or handoff to Cursor Agent."""
    if not _notify_token_ok(request.headers.get("X-Notify-Token", "")):
        return jsonify({"error": "unauthorized"}), 403
    payload = request.get_json(silent=True) or {}
    confirm_id = str(payload.get("confirm_id") or "")
    decision = str(payload.get("decision") or "").strip().lower()
    source = str(payload.get("source") or "local")
    if decision in ("allow", "confirm", "yes"):
        decision = "allow"
    elif decision in ("deny", "reject", "no"):
        decision = "deny"
    elif decision in ("cursor", "ask", "deferred"):
        decision = "cursor"
    else:
        return jsonify({"error": "bad decision"}), 400
    if not confirm_id:
        return jsonify({"error": "missing confirm_id"}), 400

    rec, applied, existing = _set_confirm_decision(
        confirm_id, decision, kind="local", source=source
    )
    if not rec:
        return jsonify({"status": "unknown"}), 404
    final = decision if applied else existing
    # Agent window resolved first -> notify Feishu group by updating the card.
    if applied and final in ("cursor", "allow", "deny") and source in (
        "agent_window",
        "cursor",
        "local",
    ):
        # Only push Feishu update for Agent-side wins (not Feishu button itself).
        if source in ("agent_window", "cursor") or (
            source == "local" and decision == "cursor"
        ):
            try:
                notify_confirm_resolved(confirm_id, final, source=source)
            except Exception as exc:
                print(f"[Confirm] feishu notify failed: {exc}", flush=True)
    return jsonify({
        "status": final,
        "confirm_id": confirm_id,
        "applied": applied,
        "existing": existing,
    })


@app.route("/local-followup/take", methods=["POST"])
def local_followup_take():
    """Stop hook pulls queued Feishu messages for this conversation."""
    if not _notify_token_ok(request.headers.get("X-Notify-Token", "")):
        return jsonify({"error": "unauthorized"}), 403
    payload = request.get_json(silent=True) or {}
    conversation_id = payload.get("conversation_id") or payload.get("id") or ""
    with _store_lock:
        items = pending_followups.pop(conversation_id, [])
    text = "\n".join(items).strip()
    return jsonify({"text": text, "count": len(items)})


def _set_confirm_decision(confirm_id, decision, agent_id="", kind="", source=""):
    """Apply allow/deny once. First writer wins; later calls are ignored.

    Returns (record, applied, existing_status).
    """
    rec = None
    applied = False
    existing = ""
    with _store_lock:
        rec = pending_confirms.get(confirm_id)
        if not rec:
            return None, False, ""
        existing = str(rec.get("status") or "")
        # Final states are immutable — prevents Feishu + Agent both acting.
        if existing in ("allow", "deny", "cursor"):
            return rec, False, existing
        if decision not in ("allow", "deny", "cursor"):
            return rec, False, existing
        rec["status"] = decision
        rec["decided_by"] = source or kind or "unknown"
        rec["decided_at"] = time.time()
        applied = True
        if decision == "allow":
            conv = rec.get("conversation_id") or agent_id
            if conv:
                # Skip re-prompting Feishu briefly after an allow (retry / double gate).
                auto_allow_until[conv] = time.time() + 180

    if applied and (kind == "cloud" or (rec and rec.get("kind") == "cloud")):
        target_id = agent_id or (rec or {}).get("conversation_id")

        def _run_cloud():
            if decision == "allow" and target_id:
                cursor_followup(target_id, "已在飞书确认，请继续执行。")
            elif decision == "deny" and target_id:
                cursor_stop_agent(target_id)

        threading.Thread(target=_run_cloud, daemon=True).start()
    return rec, applied, existing


def _confirm_result_card(confirm_id, decision, applied, existing=""):
    """Card shown after a confirm click (including duplicate clicks)."""
    if not applied and existing in ("allow", "deny", "cursor"):
        by = {
            "allow": "已确认（先到先生效，无需再点）",
            "deny": "已拒绝（先到先生效，无需再点）",
            "cursor": "已在 Cursor Agent 窗口处理，无需再点飞书",
        }.get(existing, "已处理，无需重复操作")
        color = "green" if existing == "allow" else ("red" if existing == "deny" else "blue")
        title = by
    elif decision == "allow":
        title, color = "已确认，Agent 将继续", "green"
    elif decision == "deny":
        title, color = "已拒绝", "red"
    else:
        title, color = "已交给 Cursor Agent 窗口", "blue"
    return {
        "config": {"wide_screen_mode": True, "update_multi": True},
        "header": {"title": {"tag": "plain_text", "content": title}, "template": color},
        "elements": [
            {
                "tag": "div",
                "text": {
                    "tag": "plain_text",
                    "content": "两端只需操作一次：先点的生效，另一端再点无效。",
                },
            },
            {
                "tag": "div",
                "text": {"tag": "plain_text", "content": f"confirm_id={confirm_id}"},
            },
        ],
    }


def _find_chat_id_by_name(name):
    """Exact match on conversation_id or registered chat name. No fallback."""
    name = (name or "").strip()
    if not name:
        return ""
    with _store_lock:
        if name in chat_registry:
            return name
        for cid, meta in chat_registry.items():
            if name == (meta.get("name") or ""):
                return cid
    return ""


def _resolve_chat_by_name(name):
    found = _find_chat_id_by_name(name)
    if found:
        return found
    with _store_lock:
        return last_active_chat.get("id") or ""


def _handle_feishu_card_action(body):
    action = body.get("action") or {}
    value = action.get("value") or body.get("value") or {}
    if isinstance(value, str):
        try:
            value = json.loads(value)
        except Exception:
            value = {"action": value}
    act = str(value.get("action") or "")
    confirm_id = str(value.get("confirm_id") or "")
    kind = str(value.get("kind") or "")
    agent_id = str(value.get("id") or "")
    if act in ("confirm", "deny") and confirm_id:
        decision = "allow" if act == "confirm" else "deny"
        _rec, applied, existing = _set_confirm_decision(
            confirm_id, decision, agent_id=agent_id, kind=kind, source="feishu"
        )
        card = _confirm_result_card(confirm_id, decision, applied, existing)
        # New card callback format may wrap toast + card; keep plain card for compatibility.
        if not applied and existing:
            return {
                "toast": {"type": "info", "content": "已处理，无需重复操作"},
                "card": card,
            }
        return card
    return {"code": 0}


def _extract_feishu_text(content):
    if not content:
        return ""
    if isinstance(content, dict):
        data = content
    else:
        try:
            data = json.loads(content)
        except Exception:
            return str(content)
    text = data.get("text") or data.get("content") or ""
    if isinstance(text, dict):
        text = text.get("text") or ""
    return re.sub(r"@_user_\d+", "", str(text)).strip()


def _handle_feishu_im_message(event):
    message = event.get("message") or {}
    sender = event.get("sender") or {}
    if sender.get("sender_type") == "app":
        return
    if FEISHU_CHAT_ID and message.get("chat_id") and message.get("chat_id") != FEISHU_CHAT_ID:
        return
    text = _extract_feishu_text(message.get("content"))
    if not text:
        return
    conversation_id = ""
    parent_id = message.get("parent_id") or ""
    root_id = message.get("root_id") or ""
    with _store_lock:
        if parent_id:
            conversation_id = feishu_msg_to_chat.get(parent_id, "")
        if not conversation_id and root_id:
            conversation_id = feishu_msg_to_chat.get(root_id, "")
    m = re.match(r"^(?:发送|send)\s+(\S+)\s+(.+)$", text, re.I | re.S)
    if m:
        conversation_id = _find_chat_id_by_name(m.group(1)) or _resolve_chat_by_name(m.group(1))
        text = m.group(2).strip()
    elif not conversation_id:
        first = text.split()[0] if text.split() else ""
        named = _find_chat_id_by_name(first)
        if named:
            conversation_id = named
            rest = text.split(None, 1)
            if len(rest) > 1:
                text = rest[1]
        else:
            conversation_id = last_active_chat.get("id") or ""
    # Reply to our card but mapping lost after Render restart/sleep.
    if not conversation_id and (parent_id or root_id):
        conversation_id = last_active_chat.get("id") or ""
    if not conversation_id:
        print(f"[FeishuMsg] no target chat for: {text[:80]}", flush=True)
        send_text_to_chat(
            "未找到对应 Cursor Chat。请回复通知卡片，或发送：发送 <Chat名> 内容",
            reply_to_message_id=message.get("message_id") or "",
        )
        return
    kind = "local"
    chat_name = ""
    with _store_lock:
        meta = chat_registry.get(conversation_id) or {}
        kind = meta.get("kind") or "local"
        chat_name = meta.get("name") or conversation_id
    ok = enqueue_followup(conversation_id, text, kind=kind)
    print(f"[FeishuMsg] to={conversation_id} kind={kind} ok={ok} text={text[:80]}", flush=True)
    if ok:
        if kind == "cloud":
            tip = f"已发给 Cloud Agent Chat：{chat_name}"
        else:
            tip = (
                f"已排队到本地 Chat：{chat_name}\n"
                "请在该 Cursor Chat 里再发一条消息（或等当前回合结束），"
                "stop hook 会把飞书内容注入为 followup。"
            )
    else:
        tip = f"排队失败：{chat_name}"
    send_text_to_chat(tip, reply_to_message_id=message.get("message_id") or "")


@app.route("/feishu-callback", methods=["POST"])
def feishu_callback():
    """Feishu url_verification, card clicks, and group @/reply messages."""
    body = request.get_json(silent=True) or {}
    if body.get("type") == "url_verification" or body.get("challenge"):
        if FEISHU_VERIFICATION_TOKEN and body.get("token") and body.get("token") != FEISHU_VERIFICATION_TOKEN:
            return jsonify({"error": "bad token"}), 403
        return jsonify({"challenge": body.get("challenge")})

    event_type = body.get("header", {}).get("event_type") or body.get("event", {}).get("type") or ""
    if event_type == "card.action.trigger" or body.get("action"):
        updated = _handle_feishu_card_action(body.get("event") or body)
        if isinstance(updated, dict) and (updated.get("header") or updated.get("card") or updated.get("toast")):
            return jsonify(updated)
        return jsonify({"code": 0})
    if event_type in ("im.message.receive_v1", "message"):
        _handle_feishu_im_message(body.get("event") or body)
        return jsonify({"code": 0})
    # Older card callback uses top-level action without event_type
    if "action" in body:
        updated = _handle_feishu_card_action(body)
        if isinstance(updated, dict) and (updated.get("header") or updated.get("card") or updated.get("toast")):
            return jsonify(updated)
    return jsonify({"code": 0})


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

                chat_name = _chat_name_from(agent)
                if prev_status is None and not needs_confirmation:
                    # First sighting: remember status only, do not notify historical agents.
                    agent_status_cache[agent_id] = status
                    continue

                if needs_confirmation and prev_status != "NEEDS_CONFIRMATION":
                    print(f"[轮询] 检测到需要确认: agent={agent_id}, status={status}")
                    agent_status_cache[agent_id] = "NEEDS_CONFIRMATION"
                    confirm_id = uuid.uuid4().hex[:16]
                    _register_chat(agent_id, name=chat_name, kind="cloud")
                    with _store_lock:
                        pending_confirms[confirm_id] = {
                            "status": "pending",
                            "conversation_id": agent_id,
                            "kind": "cloud",
                            "detail": status,
                            "created": time.time(),
                        }
                    payload = {
                        "id": agent_id,
                        "status": "NEEDS_CONFIRMATION",
                        "chat_name": chat_name,
                        "confirm_id": confirm_id,
                        "kind": "cloud",
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
                        "chat_name": chat_name,
                        "kind": "cloud",
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
        "known_chats": len(chat_registry),
        "pending_confirms": len(pending_confirms),
        "callback": "/feishu-callback",
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
