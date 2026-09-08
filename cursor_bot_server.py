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


def _fix_mojibake(text):
    """Best-effort repair when UTF-8 bytes were decoded as Latin-1/CP1252."""
    if not text or not isinstance(text, str):
        return ""
    s = text.strip()
    if not s:
        return ""
    # Already looks like normal CJK / ASCII — keep.
    if any("\u4e00" <= c <= "\u9fff" for c in s) and not any(c in s for c in ("Ã", "Â", "å", "æ", "ä")):
        return s
    for enc in ("latin-1", "cp1252"):
        try:
            fixed = s.encode(enc).decode("utf-8")
            if fixed and fixed != s:
                return fixed.strip()
        except Exception:
            pass
    return s


def _text_looks_ok(text):
    """Reject obvious mojibake / control-junk before putting it on Feishu cards."""
    if not text or not isinstance(text, str):
        return False
    s = text.strip()
    if not s:
        return False
    if "\ufffd" in s:
        return False
    # Classic UTF-8-as-Latin-1 mojibake markers
    bad_markers = ("Ã", "ÂÂ", "æ­", "å·", "ä¸", "æ˜", "ï¿½")
    if any(m in s for m in bad_markers):
        return False
    # Too many non-printable controls
    controls = sum(1 for c in s if ord(c) < 32 and c not in "\t\n\r")
    if controls > 0:
        return False
    return True


def _safe_display_text(text, fallback=""):
    fixed = _fix_mojibake(text)
    if _text_looks_ok(fixed):
        return fixed
    return fallback or ""


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
# Always Run: per-conversation command allowlist until Agent turn stops.
# conversation_id -> set of normalized command strings
always_run_allowlist = {}
# conversation_id / agent_id -> last known detail snapshot for Feishu "Agent 详情"
agent_details = {}


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
            "content": json.dumps(public_card, ensure_ascii=False),
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


def _confirm_result_card_compact(title, color, detail_lines):
    """Fallback when collapsible_panel is not accepted by Feishu."""
    return {
        "config": {"wide_screen_mode": True, "update_multi": True},
        "header": {
            "title": {"tag": "plain_text", "content": title},
            "template": color,
        },
        "elements": [
            {
                "tag": "div",
                "text": {
                    "tag": "plain_text",
                    "content": (detail_lines[0] if detail_lines else "已处理"),
                },
            }
        ],
    }


def notify_confirm_resolved(confirm_id, decision, source="", message_id=""):
    """After Agent-window (or other) resolve, update Feishu card so the group sees it."""
    with _store_lock:
        rec = pending_confirms.get(confirm_id) or {}
        if message_id:
            rec["message_id"] = message_id
            if confirm_id in pending_confirms:
                pending_confirms[confirm_id]["message_id"] = message_id
        message_id = message_id or rec.get("message_id") or ""
    if not message_id:
        tip = {
            "allow": "已在 Cursor Agent 窗口确认（运行），可继续。",
            "always": "已在 Cursor Agent 窗口 Always Run，可继续。",
            "deny": "已在 Cursor Agent 窗口跳过/拒绝。",
            "cursor": "已在 Cursor Agent 窗口处理，无需再点飞书。",
        }.get(decision, "确认状态已更新。")

        if source:
            tip = f"{tip}（来源：{source}）"
        send_text_to_chat(tip)
        return
    if decision == "cursor" or source in ("agent_window", "cursor"):
        card = _confirm_result_card(confirm_id, decision, applied=False, existing="cursor")
    else:
        card = _confirm_result_card(confirm_id, decision, applied=True, existing="")
    result = patch_card_message(message_id, card)
    # Older tenants / clients may reject collapsible_panel — fall back to compact card.
    if isinstance(result, dict) and result.get("code") not in (0, None) and result.get("code") != 0:
        title = ((card.get("header") or {}).get("title") or {}).get("content") or "已处理"
        color = ((card.get("header") or {})).get("template") or "grey"
        compact = _confirm_result_card_compact(title, color, ["已处理（详情已收起）"])
        patch_card_message(message_id, compact)


def _normalize_allow_cmd(detail):
    """Normalize a command/tool string for Always Run allowlist matching."""
    text = " ".join(str(detail or "").strip().split())
    return text[:500]


def _allowlist_get(conversation_id):
    with _store_lock:
        return list(always_run_allowlist.get(conversation_id) or [])


def _allowlist_add(conversation_id, detail):
    """Add one command to this chat's Always Run allowlist (until Agent stop)."""
    cmd = _normalize_allow_cmd(detail)
    if not conversation_id or not cmd:
        return []
    with _store_lock:
        bucket = always_run_allowlist.setdefault(conversation_id, set())
        bucket.add(cmd)
        return list(bucket)


def _allowlist_match(conversation_id, detail):
    cmd = _normalize_allow_cmd(detail)
    if not conversation_id or not cmd:
        return False
    cmd_first = cmd.split(" ", 1)[0].lower()
    with _store_lock:
        bucket = always_run_allowlist.get(conversation_id) or set()
        if cmd in bucket:
            return True
        for item in bucket:
            if cmd.startswith(item) or item.startswith(cmd):
                return True
            item_first = item.split(" ", 1)[0].lower()
            if cmd_first and item_first and cmd_first == item_first:
                return True
    return False


def _arm_auto_allow(conversation_id, mode="always", ttl_sec=None, detail=""):
    """Arm Always Run for a specific command until Agent stop."""
    if not conversation_id or mode != "always":
        return
    _allowlist_add(conversation_id, detail)


def _clear_always_run(conversation_id):
    """Clear Always Run allowlist when Agent turn ends or user skips/denies."""
    if not conversation_id:
        return
    with _store_lock:
        always_run_allowlist.pop(conversation_id, None)


def _auto_allow_state(conversation_id, detail=""):
    """Return (active: bool, mode: str). Only matching allowlisted commands are silent."""
    if not conversation_id:
        return False, ""
    if _allowlist_match(conversation_id, detail):
        return True, "always"
    return False, ""


def _fold_sibling_pendings(conversation_id, decision, exclude_id="", source="feishu"):
    """Mark other pending confirms in the same chat as decided (update existing cards only)."""
    if not conversation_id or decision not in ("allow", "always", "deny", "cursor"):
        return []
    now = time.time()
    siblings = []
    with _store_lock:
        for cid, rec in list(pending_confirms.items()):
            if exclude_id and cid == exclude_id:
                continue
            if rec.get("conversation_id") != conversation_id:
                continue
            if str(rec.get("status") or "") != "pending":
                continue
            rec["status"] = decision
            rec["decided_by"] = source
            rec["decided_at"] = now
            siblings.append(cid)
    for cid in siblings:
        try:
            notify_confirm_resolved(cid, decision, source=source)
            print(f"[Confirm] fold sibling {cid} -> {decision}", flush=True)
        except Exception as exc:
            print(f"[Confirm] fold sibling failed {cid}: {exc}", flush=True)
    return siblings


def _resolve_pending_for_conversation(
    conversation_id, source="agent_window", exclude_id="", min_age_sec=0, notify=True
):
    """Mark leftover pending confirms as resolved in Agent window and update Feishu cards.

    Used when the next confirm arrives or the Agent turn stops — UIA often cannot
    see Cursor Auto-review buttons, so the watcher never calls /decide.

    min_age_sec: only resolve pendings older than this (avoids killing a twin hook
    that fired 1s earlier for the same shell/tool on Remote SSH).
    notify: when False, only update memory (no Feishu patch/text) — used under Always Run.
    """
    if not conversation_id:
        return []
    now = time.time()
    to_notify = []
    with _store_lock:
        for cid, rec in list(pending_confirms.items()):
            if exclude_id and cid == exclude_id:
                continue
            if rec.get("conversation_id") != conversation_id:
                continue
            if str(rec.get("status") or "") != "pending":
                continue
            created = float(rec.get("created") or 0)
            if min_age_sec and created and (now - created) < min_age_sec:
                continue
            rec["status"] = "cursor"
            rec["decided_by"] = source
            rec["decided_at"] = now
            to_notify.append(cid)
    if not notify:
        return to_notify
    for cid in to_notify:
        try:
            notify_confirm_resolved(cid, "cursor", source=source)
            print(f"[Confirm] auto-resolve {cid} source={source}", flush=True)
        except Exception as exc:
            print(f"[Confirm] auto-resolve failed {cid}: {exc}", flush=True)
    return to_notify


def _notify_token_ok(token):
    secret = CURSOR_WEBHOOK_SECRET or ""
    token = token or ""
    return bool(secret) and len(token) == len(secret) and hmac.compare_digest(token, secret)


def _register_chat(conversation_id, **meta):
    if not conversation_id:
        return
    with _store_lock:
        row = chat_registry.get(conversation_id, {})
        new_aliases = meta.pop("aliases", None) if "aliases" in meta else None
        row.update({k: v for k, v in meta.items() if v})
        aliases = list(row.get("aliases") or [])
        for a in (new_aliases or []):
            if a and a not in aliases:
                aliases.append(a)
        name = row.get("name") or ""
        if name and name not in aliases:
            aliases.append(name)
        ws = str(row.get("workspace") or "").replace(chr(92), "/").rstrip("/")
        leaf = os.path.basename(ws) if ws else ""
        if leaf and leaf not in aliases:
            aliases.append(leaf)
        if aliases:
            row["aliases"] = aliases
        row["last_seen"] = time.time()
        chat_registry[conversation_id] = row
        last_active_chat["id"] = conversation_id


def _normalize_workspace(workspace):
    workspace = str(workspace or "")
    if workspace.startswith("/") and len(workspace) > 2 and workspace[2] == ":":
        workspace = workspace[1:]
    return workspace


def _chat_name_from(payload, workspace=""):
    workspace = _normalize_workspace(workspace or payload.get("workspace") or "")
    ws_leaf = os.path.basename(workspace.replace(chr(92), "/").rstrip("/")) if workspace else ""
    name = (
        payload.get("chat_name")
        or payload.get("conversation_title")
        or payload.get("title")
        or ""
    )
    name = _safe_display_text(name, "")
    if not name and ws_leaf:
        name = ws_leaf
    if not name:
        name = _safe_display_text(payload.get("name") or "", "")
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


def _remember_agent_detail(agent_id, **fields):
    """Keep a snapshot so Feishu 'Agent 详情' can expand without opening cursor.com."""
    if not agent_id:
        return
    with _store_lock:
        prev = agent_details.get(agent_id) or {}
        merged = dict(prev)
        for key, value in fields.items():
            if value is None:
                continue
            text = str(value).strip()
            if text:
                merged[key] = text
        merged["updated_at"] = time.time()
        agent_details[agent_id] = merged


def _is_useful_agent_url(url):
    """True only for a real Cloud Agent / PR deep link — never marketing homepage."""
    u = (url or "").strip().lower().rstrip("/")
    if not u:
        return False
    # Bare site / www — never treat as Agent detail link
    if u in (
        "https://cursor.com",
        "http://cursor.com",
        "https://www.cursor.com",
        "http://www.cursor.com",
        "https://cursor.com/home",
        "https://www.cursor.com/home",
    ):
        return False
    if "cursor.com/agents" in u:
        return True
    if "github.com/" in u or "gitlab.com/" in u:
        return True
    return False


def _status_label_zh(status):
    return {
        "FINISHED": "已完成",
        "COMPLETED": "已完成",
        "ERROR": "出错",
        "FAILED": "失败",
        "RUNNING": "运行中",
        "NEEDS_CONFIRMATION": "待确认",
    }.get(str(status or "").upper(), str(status or "未知"))


def _agent_detail_lines(agent_id, payload=None):
    """Build markdown lines for Agent run status (shown inside Feishu card)."""
    payload = payload or {}
    with _store_lock:
        snap = dict(agent_details.get(agent_id) or {})
        reg = dict(chat_registry.get(agent_id) or {})
    chat_name = (
        payload.get("chat_name")
        or snap.get("chat_name")
        or reg.get("name")
        or ""
    )
    kind = payload.get("kind") or snap.get("kind") or reg.get("kind") or ""
    machine = payload.get("machine") or snap.get("machine") or reg.get("machine") or ""
    model = payload.get("model") or snap.get("model") or ""
    workspace = (
        payload.get("workspace")
        or (payload.get("source") or {}).get("repository")
        or snap.get("workspace")
        or reg.get("workspace")
        or ""
    )
    status = payload.get("status") or snap.get("status") or ""
    summary = payload.get("summary") or snap.get("summary") or ""
    branch = (payload.get("source") or {}).get("ref") or snap.get("ref") or ""
    url = (payload.get("target") or {}).get("url") or snap.get("url") or ""

    kind_zh = {"local": "本地 Agent", "cloud": "Cloud Agent"}.get(str(kind), kind or "未知")

    lines = ["**运行情况**"]
    lines.append(f"**结果:** {_status_label_zh(status)}")
    if chat_name:
        lines.append(f"**Chat:** {chat_name}")
    lines.append(f"**会话 ID:** `{agent_id or '未知'}`")
    lines.append(f"**类型:** {kind_zh}")
    if machine:
        lines.append(f"**机器:** {machine}")
    if model:
        lines.append(f"**模型:** `{model}`")
    if workspace:
        lines.append(f"**工作区:** `{workspace}`")
    if branch:
        lines.append(f"**分支:** `{branch}`")

    # Token / loop metrics from stop hook when available
    def _num(key):
        for src in (payload, snap):
            v = src.get(key)
            if v is None or v == "":
                continue
            try:
                return int(float(v))
            except Exception:
                return str(v)
        return None

    loop_count = _num("loop_count")
    in_tok = _num("input_tokens")
    out_tok = _num("output_tokens")
    cache_r = _num("cache_read_tokens")
    cache_w = _num("cache_write_tokens")
    metric_parts = []
    if loop_count is not None:
        metric_parts.append(f"loop={loop_count}")
    if in_tok is not None:
        metric_parts.append(f"input={in_tok}")
    if out_tok is not None:
        metric_parts.append(f"output={out_tok}")
    if cache_r is not None:
        metric_parts.append(f"cache_read={cache_r}")
    if cache_w is not None:
        metric_parts.append(f"cache_write={cache_w}")
    if metric_parts:
        lines.append(f"**用量:** {' · '.join(metric_parts)}")

    if summary:
        # Keep summary readable; strip markdown bold noise from server-composed lines
        clean = str(summary).replace("**", "").strip()
        lines.append(f"**摘要:** {clean[:800]}")
    if _is_useful_agent_url(url):
        lines.append(f"**Cloud 链接:** {url}")
    updated = snap.get("updated_at")
    if updated:
        try:
            lines.append(
                f"**更新时间:** {time.strftime('%Y-%m-%d %H:%M:%S', time.localtime(float(updated)))}"
            )
        except Exception:
            pass
    return lines


def _build_agent_detail_card(agent_id, base_payload=None):
    """Card returned when user taps 运行情况 / Agent 详情 on Feishu."""
    base_payload = dict(base_payload or {})
    base_payload.setdefault("id", agent_id)
    with _store_lock:
        snap = dict(agent_details.get(agent_id) or {})
    status = base_payload.get("status") or snap.get("status") or "FINISHED"
    status_map = {
        "FINISHED": ("📋 运行情况", "blue"),
        "ERROR": ("📋 运行情况（出错）", "red"),
        "NEEDS_CONFIRMATION": ("📋 运行情况（待确认）", "orange"),
        "RUNNING": ("📋 运行情况（运行中）", "blue"),
    }
    title, color = status_map.get(status, ("📋 运行情况", "blue"))
    lines = _agent_detail_lines(agent_id, {**snap, **base_payload, "status": status})
    elements = [
        {"tag": "div", "text": {"tag": "lark_md", "content": "\n".join(lines)}},
        {
            "tag": "action",
            "actions": [
                {
                    "tag": "button",
                    "text": {"tag": "plain_text", "content": "返回摘要"},
                    "type": "default",
                    "value": {
                        "action": "agent_summary",
                        "id": agent_id,
                        "kind": base_payload.get("kind") or snap.get("kind") or "",
                    },
                }
            ],
        },
    ]
    # Never attach cursor.com. Only real Cloud Agent / PR deep links as a separate button.
    url = (base_payload.get("target") or {}).get("url") or snap.get("url") or ""
    if _is_useful_agent_url(url):
        elements[1]["actions"].insert(0, {
            "tag": "button",
            "text": {"tag": "plain_text", "content": "打开 Cloud Agent"},
            "url": url,
            "type": "default",
        })
    return {
        "config": {"wide_screen_mode": True, "update_multi": True},
        "header": {"title": {"tag": "plain_text", "content": title}, "template": color},
        "elements": elements,
        "_conversation_id": agent_id,
    }


def build_cursor_card(payload, status_label=None):
    """构建飞书交互卡片"""
    status = payload.get("status", "UNKNOWN")
    summary = payload.get("summary", "无摘要")
    agent_id = payload.get("id", "未知")
    target = payload.get("target", {}) or {}
    source = payload.get("source", {}) or {}
    chat_name = payload.get("chat_name") or payload.get("name") or ""
    confirm_id = payload.get("confirm_id") or ""
    kind = payload.get("kind") or ""
    machine = payload.get("machine") or ""
    model = payload.get("model") or ""
    detail_cmd = _safe_display_text(str(payload.get("detail") or ""), "")
    always_cmds = payload.get("always_run_commands") or []
    if not isinstance(always_cmds, list):
        always_cmds = []
    always_existing = payload.get("always_run_existing") or []
    if not isinstance(always_existing, list):
        always_existing = []

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
    if kind:
        info_lines.append(f"**类型:** `{kind}`")
    if machine:
        info_lines.append(f"**机器:** {machine}")
    if model:
        info_lines.append(f"**模型:** `{model}`")
    info_lines.append(f"**摘要:** {summary}")

    elements = [
        {"tag": "div", "text": {"tag": "lark_md", "content": "\n".join(info_lines)}},
        {"tag": "div", "text": {"tag": "lark_md",
            "content": f"**仓库/工作区:** {source.get('repository', 'N/A')}\n**分支:** `{source.get('ref', 'N/A') or 'N/A'}`"}},
    ]

    if confirm_id or status == "NEEDS_CONFIRMATION":
        always_lines = [
            "确认方式（与 Cursor Agent 同序）：**跳过 / Always Run / 运行**；飞书或 Agent 窗口先点的生效。",
        ]
        show_cmd = detail_cmd or (always_cmds[0] if always_cmds else "")
        if show_cmd:
            always_lines.append("**Always Run 将加入白名单的命令：**")
            always_lines.append(f"- `{show_cmd[:300]}`")
        else:
            always_lines.append("**Always Run 将加入白名单的命令：**（当前未解析到具体命令）")
        if always_existing:
            always_lines.append("**本回合已在白名单：**")
            for c in always_existing[:8]:
                c = _safe_display_text(str(c), "")
                if c:
                    always_lines.append(f"- `{c[:300]}`")
        always_lines.append(
            "说明：Always Run 只自动放行白名单中的命令（同 Chat 内跨回合仍有效）；其他命令仍会确认。点「跳过」会清空白名单。"
        )
        always_lines.append(
            f"向该 Chat 发消息：回复本卡片并 @机器人，或 `@机器人 发送 {chat_name or agent_id} 你的内容`"
        )
        elements.append({"tag": "div", "text": {"tag": "lark_md",
            "content": chr(10).join(always_lines)}})
    else:
        elements.append({"tag": "div", "text": {"tag": "lark_md",
            "content": (
                f"向该 Chat 发消息：回复本卡片并 @机器人，或 `@机器人 发送 {chat_name or agent_id} 你的内容`\n"
                f"点击 **运行情况** 可在卡片内查看本次 Agent 运行详情（不会打开 Cursor 官网）。"
            )}})

    actions = []
    if confirm_id:
        # Match Cursor Agent approval order: Skip | Always Run | Run
        actions.append({
            "tag": "button",
            "text": {"tag": "plain_text", "content": "跳过"},
            "type": "default",
            "value": {"action": "deny", "confirm_id": confirm_id, "kind": kind or "local", "id": agent_id},
        })
        actions.append({
            "tag": "button",
            "text": {"tag": "plain_text", "content": "Always Run"},
            "type": "default",
            "value": {"action": "always", "confirm_id": confirm_id, "kind": kind or "local", "id": agent_id},
        })
        actions.append({
            "tag": "button",
            "text": {"tag": "plain_text", "content": "运行"},
            "type": "primary",
            "value": {"action": "confirm", "confirm_id": confirm_id, "kind": kind or "local", "id": agent_id},
        })
    if target.get("prUrl"):
        actions.append({"tag": "button", "text": {"tag": "plain_text", "content": "查看 PR"},
            "url": target["prUrl"], "type": "primary"})

    useful_url = target.get("url") if _is_useful_agent_url(target.get("url")) else ""
    # Completion cards: in-card run status only — never link Agent 详情 to cursor.com
    if status in ("FINISHED", "ERROR", "RUNNING") or (not confirm_id and status != "NEEDS_CONFIRMATION"):
        actions.append({
            "tag": "button",
            "text": {"tag": "plain_text", "content": "运行情况"},
            "type": "primary",
            "value": {
                "action": "agent_detail",
                "id": agent_id,
                "kind": kind or "",
                "status": status,
            },
        })
    if useful_url:
        actions.append({
            "tag": "button",
            "text": {"tag": "plain_text", "content": "打开 Cloud Agent"},
            "url": useful_url,
            "type": "default",
        })
    if status == "NEEDS_CONFIRMATION" and useful_url and not confirm_id:
        actions.append({"tag": "button", "text": {"tag": "plain_text", "content": "去确认"},
            "url": useful_url, "type": "primary"})

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
    target = payload.get("target") or {}
    source = payload.get("source") or {}
    _remember_agent_detail(
        agent_id,
        chat_name=payload.get("chat_name"),
        kind="cloud",
        status=status,
        summary=payload.get("summary"),
        workspace=source.get("repository"),
        ref=source.get("ref"),
        url=target.get("url"),
        pr_url=target.get("prUrl"),
    )

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

    run_metrics = {
        "loop_count": payload.get("loop_count"),
        "input_tokens": payload.get("input_tokens"),
        "output_tokens": payload.get("output_tokens"),
        "cache_read_tokens": payload.get("cache_read_tokens"),
        "cache_write_tokens": payload.get("cache_write_tokens"),
    }

    card_payload = {
        "id": agent_id,
        "status": status,
        "chat_name": chat_name,
        "kind": "local",
        "machine": machine,
        "model": model,
        "workspace": workspace,
        "summary": summary,
        "source": {"repository": workspace or "local", "ref": payload.get("ref", "")},
        "target": {},
        **{k: v for k, v in run_metrics.items() if v is not None and str(v) != ""},
    }
    # Never default to cursor.com. Only keep a real Cloud / PR deep-link if provided.
    raw_url = str(payload.get("url") or "").strip()
    if _is_useful_agent_url(raw_url):
        card_payload["target"]["url"] = raw_url
    _remember_agent_detail(
        agent_id,
        chat_name=chat_name,
        kind="local",
        status=status,
        summary=summary,
        machine=machine,
        model=model,
        workspace=workspace,
        ref=payload.get("ref", ""),
        url=card_payload["target"].get("url", ""),
        **{k: v for k, v in run_metrics.items() if v is not None and str(v) != ""},
    )
    print(f"[Local] 收到本地 Agent 通知: agent={agent_id}, status={status}, machine={machine}", flush=True)
    # Agent turn ended — fold leftover confirms.
    # Keep Always Run allowlist across turns (same chat); only Skip/Deny clears it.
    had_always = bool(_allowlist_get(agent_id))
    _resolve_pending_for_conversation(
        agent_id, source="agent_window", notify=(not had_always)
    )
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
    detail_raw = payload.get("detail") or payload.get("command") or payload.get("tool") or ""
    detail = _safe_display_text(str(detail_raw), "")
    _register_chat(conversation_id, name=chat_name, machine=machine, kind="local", workspace=workspace)

    # Always Run / recent allow: silently allow — do NOT send another Feishu confirm card.
    active, mode = _auto_allow_state(conversation_id, detail)
    if active:
        print(
            f"[Confirm] auto_allow skip Feishu conv={conversation_id} mode={mode} detail={detail[:80]}",
            flush=True,
        )
        # Clear leftover pendings quietly under Always Run (no extra Feishu traffic).
        if mode == "always":
            _resolve_pending_for_conversation(
                conversation_id, source="auto_allow", notify=False
            )
        return jsonify({
            "confirm_id": "",
            "status": "allow",
            "auto_allow": True,
            "always": mode == "always",
            "message_id": "",
            "allowlist": _allowlist_get(conversation_id),
            "matched": _normalize_allow_cmd(detail),
        })

    # Reuse a very-recent pending confirm (duplicate hook: beforeShell + Task, etc.)
    with _store_lock:
        now = time.time()
        for cid, rec in list(pending_confirms.items()):
            if rec.get("conversation_id") != conversation_id:
                continue
            if str(rec.get("status") or "") != "pending":
                continue
            created = float(rec.get("created") or 0)
            if created and (now - created) <= 8:
                print(f"[Confirm] reuse pending {cid} age={now - created:.2f}s", flush=True)
                return jsonify({
                    "confirm_id": cid,
                    "status": "pending",
                    "auto_allow": False,
                    "message_id": rec.get("message_id") or "",
                    "reused": True,
                })

    # Only fold truly stale pendings (Agent already moved on), not the twin hook 1s ago.
    _resolve_pending_for_conversation(
        conversation_id, source="agent_window", min_age_sec=20
    )

    confirm_id = uuid.uuid4().hex[:16]
    with _store_lock:
        pending_confirms[confirm_id] = {
            "status": "pending",
            "conversation_id": conversation_id,
            "kind": "local",
            "detail": detail or "需要确认的操作",
            "created": time.time(),
            "message_id": "",
        }
    # Compose Chinese on the server — never trust hook encoding for card copy.
    summary_lines = ["需要确认的操作"]
    if machine:
        summary_lines.insert(0, f"机器: {machine}")
    if detail:
        summary_lines.append(detail[:500])
    card = build_cursor_card({
        "id": conversation_id,
        "status": "NEEDS_CONFIRMATION",
        "chat_name": chat_name,
        "confirm_id": confirm_id,
        "kind": "local",
        "detail": detail,
        "always_run_commands": [detail] if detail else [],
        "always_run_existing": _allowlist_get(conversation_id),
        "summary": "\n".join(summary_lines),
        "source": {"repository": workspace or "local", "ref": ""},
        "target": {},
    }, status_label="需要确认")
    card["_confirm_id"] = confirm_id
    send_result = send_card_to_chat(card)
    message_id = ""
    try:
        message_id = ((send_result or {}).get("data") or {}).get("message_id") or ""
    except Exception:
        message_id = ""
    with _store_lock:
        if confirm_id in pending_confirms and message_id:
            pending_confirms[confirm_id]["message_id"] = message_id
    return jsonify({
        "confirm_id": confirm_id,
        "status": "pending",
        "auto_allow": False,
        "message_id": message_id,
    })


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
    conv = rec.get("conversation_id") or ""
    return jsonify({
        "status": rec.get("status"),
        "conversation_id": conv,
        "detail": rec.get("detail") or "",
        "allowlist": _allowlist_get(conv) if conv else [],
    })


@app.route("/local-confirm/pending", methods=["GET"])
def local_confirm_pending():
    """List recent confirms for the Windows peer bridge (Remote SSH + local).

    Includes pending items and recently decided ones so the local UIA bridge can
    still click Agent Allow/Deny after Feishu wins.
    """
    if not _notify_token_ok(request.headers.get("X-Notify-Token", "")):
        return jsonify({"error": "unauthorized"}), 403
    now = time.time()
    items = []
    with _store_lock:
        for cid, rec in list(pending_confirms.items()):
            status = str(rec.get("status") or "")
            created = float(rec.get("created") or 0)
            age = now - created if created else 0
            if status == "pending" and age <= 180:
                pass
            elif status in ("allow", "always", "deny", "cursor") and age <= 180:
                pass
            else:
                continue
            items.append({
                "confirm_id": cid,
                "status": status,
                "message_id": rec.get("message_id") or "",
                "conversation_id": rec.get("conversation_id") or "",
                "created": created,
                "detail": rec.get("detail") or "",
            })
    items.sort(key=lambda x: x.get("created") or 0, reverse=True)
    return jsonify({"items": items, "count": len(items)})


@app.route("/local-confirm/decide", methods=["POST"])
def local_confirm_decide():
    """Record allow/deny from Feishu, local client, or handoff to Cursor Agent."""
    if not _notify_token_ok(request.headers.get("X-Notify-Token", "")):
        return jsonify({"error": "unauthorized"}), 403
    payload = request.get_json(silent=True) or {}
    confirm_id = str(payload.get("confirm_id") or "")
    decision = str(payload.get("decision") or "").strip().lower()
    source = str(payload.get("source") or "local")
    message_id = str(payload.get("message_id") or "")
    if decision in ("allow", "confirm", "yes", "run"):
        decision = "allow"
    elif decision in ("always", "always_run", "always-run", "alwaysrun"):
        decision = "always"
    elif decision in ("deny", "reject", "no", "skip"):
        decision = "deny"
    elif decision in ("cursor", "ask", "deferred"):
        decision = "cursor"
    else:
        return jsonify({"error": "bad decision"}), 400
    if not confirm_id:
        return jsonify({"error": "missing confirm_id"}), 400

    if message_id:
        with _store_lock:
            if confirm_id in pending_confirms:
                pending_confirms[confirm_id]["message_id"] = message_id

    rec, applied, existing = _set_confirm_decision(
        confirm_id, decision, kind="local", source=source
    )
    if not rec:
        # Record lost (Render restart) but client still has message_id — patch card anyway.
        if message_id and decision in ("cursor", "allow", "always", "deny") and source in (
            "agent_window",
            "cursor",
        ):
            try:
                notify_confirm_resolved(
                    confirm_id, decision, source=source, message_id=message_id
                )
            except Exception as exc:
                print(f"[Confirm] feishu notify (orphan) failed: {exc}", flush=True)
            return jsonify({
                "status": decision,
                "confirm_id": confirm_id,
                "applied": True,
                "existing": "",
                "orphan": True,
            })
        return jsonify({"status": "unknown"}), 404
    final = decision if applied else existing
    # Agent window resolved first -> notify Feishu group by updating the card.
    if applied and final in ("cursor", "allow", "always", "deny") and source in (
        "agent_window",
        "cursor",
        "local",
    ):
        # Only push Feishu update for Agent-side wins (not Feishu button itself).
        if source in ("agent_window", "cursor") or (
            source == "local" and decision == "cursor"
        ):
            try:
                notify_confirm_resolved(
                    confirm_id, final, source=source, message_id=message_id
                )
            except Exception as exc:
                print(f"[Confirm] feishu notify failed: {exc}", flush=True)
    conv = ""
    detail = ""
    if rec:
        conv = rec.get("conversation_id") or ""
        detail = rec.get("detail") or ""
    return jsonify({
        "status": final,
        "confirm_id": confirm_id,
        "applied": applied,
        "existing": existing,
        "conversation_id": conv,
        "detail": detail,
        "allowlist": _allowlist_get(conv) if conv else [],
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
        if existing in ("allow", "always", "deny", "cursor"):
            return rec, False, existing
        if decision not in ("allow", "always", "deny", "cursor"):
            return rec, False, existing
        rec["status"] = decision
        rec["decided_by"] = source or kind or "unknown"
        rec["decided_at"] = time.time()
        applied = True
        if decision == "always":
            conv = rec.get("conversation_id") or agent_id
            cmd = _normalize_allow_cmd(rec.get("detail") or "")
            if conv and cmd:
                bucket = always_run_allowlist.setdefault(conv, set())
                bucket.add(cmd)
        elif decision == "deny":
            conv = rec.get("conversation_id") or agent_id
            if conv:
                always_run_allowlist.pop(conv, None)

    if applied and decision == "always":
        conv = (rec or {}).get("conversation_id") or agent_id
        if conv:
            # Fold twin pending cards for this chat; do not create new Feishu messages.
            threading.Thread(
                target=_fold_sibling_pendings,
                kwargs={"conversation_id": conv, "decision": "always", "exclude_id": confirm_id, "source": source or "feishu"},
                daemon=True,
            ).start()

    if applied and (kind == "cloud" or (rec and rec.get("kind") == "cloud")):
        target_id = agent_id or (rec or {}).get("conversation_id")

        def _run_cloud():
            if decision in ("allow", "always") and target_id:
                cursor_followup(target_id, "已在飞书确认，请继续执行。")
            elif decision == "deny" and target_id:
                cursor_stop_agent(target_id)

        threading.Thread(target=_run_cloud, daemon=True).start()
    return rec, applied, existing


def _confirm_result_card(confirm_id, decision, applied, existing=""):
    """Card shown after a confirm click (including duplicate clicks).

    Color scheme vs pending (orange):
      allow / always -> green
      deny   -> red
      cursor / already handled -> grey (closed / no longer actionable)

    Resolved cards are collapsed: colored header + details in a folded panel.
    """
    finals = ("allow", "always", "deny", "cursor")
    state = existing if (not applied and existing in finals) else decision
    if not applied and existing in finals:
        by = {
            "allow": "已处理 - 已运行（无需再点）",
            "always": "已处理 - Always Run（无需再点）",
            "deny": "已处理 - 已跳过（无需再点）",
            "cursor": "已处理 - 已在 Cursor Agent 窗口处理",
        }.get(existing, "已处理，无需重复操作")
        title = by
    elif decision == "allow":
        title = "已处理 - 已运行，Agent 将继续"
    elif decision == "always":
        title = "已处理 - Always Run，已将命令加入本回合白名单"
    elif decision == "deny":
        title = "已处理 - 已跳过"
    else:
        title = "已处理 - 已在 Cursor Agent 窗口处理"

    if state in ("allow", "always"):
        color = "green"
    elif state == "deny":
        color = "red"
    else:
        color = "grey"

    chat_name = ""
    detail = ""
    with _store_lock:
        rec = pending_confirms.get(confirm_id) or {}
        conv = rec.get("conversation_id") or ""
        detail = _safe_display_text(str(rec.get("detail") or ""), "")
        if conv and conv in chat_registry:
            chat_name = _safe_display_text(str(chat_registry[conv].get("name") or ""), "")

    allowlist_now = _allowlist_get(conv) if conv else []
    detail_lines = [
        "此确认已处理。",
        "两端只需操作一次：先点的生效，另一端再点无效。",
    ]
    if chat_name:
        detail_lines.insert(0, f"Chat: {chat_name}")
    if detail and detail != "需要确认的操作":
        detail_lines.append(f"详情: {detail[:200]}")
    if state == "always" or decision == "always":
        if detail and detail != "需要确认的操作":
            detail_lines.append(f"已加入白名单: {detail[:300]}")
        if allowlist_now:
            detail_lines.append("本回合白名单:")
            for c in allowlist_now[:10]:
                detail_lines.append(f"- {c[:300]}")
        detail_lines.append("仅白名单中的命令会自动放行（同 Chat 跨回合有效）；其他命令仍会确认。点跳过会清空。")
    detail_lines.append(f"confirm_id={confirm_id}")

    # Default collapsed so the group timeline stays short after either side resolves.
    return {
        "config": {"wide_screen_mode": True, "update_multi": True},
        "header": {
            "title": {"tag": "plain_text", "content": title},
            "template": color,
        },
        "elements": [
            {
                "tag": "collapsible_panel",
                "expanded": False,
                "header": {
                    "title": {
                        "tag": "plain_text",
                        "content": "查看详情（已折叠，点击展开）",
                    },
                    "vertical_align": "center",
                    "icon": {
                        "tag": "standard_icon",
                        "token": "down-small-ccm_outlined",
                        "size": "16px 16px",
                    },
                    "icon_position": "right",
                    "icon_expanded_angle": -180,
                },
                "border": {"color": "grey", "corner_radius": "5px"},
                "vertical_spacing": "4px",
                "padding": "4px 8px 4px 8px",
                "elements": [
                    {
                        "tag": "div",
                        "text": {
                            "tag": "plain_text",
                            "content": "\n".join(detail_lines),
                        },
                    }
                ],
            }
        ],
    }


def _public_card(card_content):
    return {k: v for k, v in (card_content or {}).items() if not str(k).startswith("_")}


def _feishu_card_callback_body(card, toast=None, new_format=True):
    """Build Feishu card-action response (v2 needs type=raw wrapper)."""
    data = _public_card(card)
    if new_format:
        body = {"card": {"type": "raw", "data": data}}
        if toast:
            body["toast"] = toast
        return body
    if toast:
        return {"toast": toast, **data}
    return data


def _patch_confirm_card(confirm_id, card):
    """Best-effort PATCH so the whole group sees the new header color / folded card."""
    with _store_lock:
        rec = pending_confirms.get(confirm_id) or {}
        message_id = rec.get("message_id") or ""
    if not message_id:
        return
    try:
        result = patch_card_message(message_id, card)
        if isinstance(result, dict) and result.get("code") not in (0, None) and result.get("code") != 0:
            title = ((card.get("header") or {}).get("title") or {}).get("content") or "已处理"
            color = ((card.get("header") or {})).get("template") or "grey"
            patch_card_message(
                message_id,
                _confirm_result_card_compact(title, color, ["已处理（详情已收起）"]),
            )
    except Exception as exc:
        print(f"[飞书] patch confirm card failed: {exc}", flush=True)


def _find_chat_id_by_name(name):
    """Exact match on conversation_id, registered chat name, workspace leaf, or aliases."""
    name = (name or "").strip()
    if not name:
        return ""
    with _store_lock:
        if name in chat_registry:
            return name
        name_l = name.lower()
        for cid, meta in chat_registry.items():
            if name == (meta.get("name") or ""):
                return cid
            ws = str(meta.get("workspace") or "").replace(chr(92), "/").rstrip("/")
            if ws and name == os.path.basename(ws):
                return cid
            aliases = meta.get("aliases") or []
            if isinstance(aliases, (list, tuple)) and name in aliases:
                return cid
            if name_l and name_l == str(meta.get("name") or "").lower():
                return cid
    return ""


def _resolve_chat_by_name(name):
    found = _find_chat_id_by_name(name)
    if found:
        return found
    with _store_lock:
        return last_active_chat.get("id") or ""


def _handle_feishu_card_action(body, new_format=True):
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
    if act in ("confirm", "always", "deny") and confirm_id:
        if act == "confirm":
            decision = "allow"
        elif act == "always":
            decision = "always"
        else:
            decision = "deny"
        _rec, applied, existing = _set_confirm_decision(
            confirm_id, decision, agent_id=agent_id, kind=kind, source="feishu"
        )
        card = _confirm_result_card(confirm_id, decision, applied, existing)
        # Also PATCH by message_id so color change is visible to the whole group.
        _patch_confirm_card(confirm_id, card)
        toast = None
        if not applied and existing:
            toast = {"type": "info", "content": "已处理，无需重复操作"}
        elif applied and decision == "allow":
            toast = {"type": "success", "content": "已运行"}
        elif applied and decision == "always":
            toast = {"type": "success", "content": "Always Run"}
        elif applied and decision == "deny":
            toast = {"type": "warning", "content": "已跳过"}
        return _feishu_card_callback_body(card, toast=toast, new_format=new_format)

    if act == "agent_detail" and agent_id:
        with _store_lock:
            snap = dict(agent_details.get(agent_id) or {})
        base = {
            "id": agent_id,
            "kind": value.get("kind") or snap.get("kind") or "",
            "status": value.get("status") or snap.get("status") or "FINISHED",
            "chat_name": snap.get("chat_name") or "",
            "machine": snap.get("machine") or "",
            "model": snap.get("model") or "",
            "workspace": snap.get("workspace") or "",
            "summary": snap.get("summary") or "",
            "source": {
                "repository": snap.get("workspace") or "",
                "ref": snap.get("ref") or "",
            },
            "target": {"url": snap.get("url") or ""},
        }
        card = _build_agent_detail_card(agent_id, base)
        return _feishu_card_callback_body(
            card,
            toast={"type": "info", "content": "已展开运行情况"},
            new_format=new_format,
        )

    if act == "agent_summary" and agent_id:
        with _store_lock:
            snap = dict(agent_details.get(agent_id) or {})
        status = snap.get("status") or "FINISHED"
        card = build_cursor_card({
            "id": agent_id,
            "status": status,
            "chat_name": snap.get("chat_name") or "",
            "kind": snap.get("kind") or "",
            "machine": snap.get("machine") or "",
            "model": snap.get("model") or "",
            "workspace": snap.get("workspace") or "",
            "summary": snap.get("summary") or "无摘要",
            "source": {
                "repository": snap.get("workspace") or "local",
                "ref": snap.get("ref") or "",
            },
            "target": {"url": snap.get("url") or ""} if _is_useful_agent_url(snap.get("url")) else {},
        })
        return _feishu_card_callback_body(
            card,
            toast={"type": "info", "content": "已返回摘要"},
            new_format=new_format,
        )

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
    new_card_cb = (
        event_type == "card.action.trigger"
        or body.get("schema") == "2.0"
        or str(body.get("header", {}).get("event_type") or "") == "card.action.trigger"
    )
    if event_type == "card.action.trigger" or body.get("action"):
        updated = _handle_feishu_card_action(
            body.get("event") or body, new_format=new_card_cb
        )
        if isinstance(updated, dict) and (updated.get("header") or updated.get("card") or updated.get("toast")):
            return jsonify(updated)
        return jsonify({"code": 0})
    if event_type in ("im.message.receive_v1", "message"):
        _handle_feishu_im_message(body.get("event") or body)
        return jsonify({"code": 0})
    # Older card callback uses top-level action without event_type
    if "action" in body:
        updated = _handle_feishu_card_action(body, new_format=False)
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
                    src = payload["source"] if isinstance(payload["source"], dict) else {}
                    _remember_agent_detail(
                        agent_id,
                        chat_name=chat_name,
                        kind="cloud",
                        status="NEEDS_CONFIRMATION",
                        summary=payload["summary"],
                        workspace=src.get("repository"),
                        ref=src.get("ref"),
                        url=payload["target"]["url"],
                        pr_url=payload["target"].get("prUrl"),
                    )
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
                    src = payload["source"] if isinstance(payload["source"], dict) else {}
                    _remember_agent_detail(
                        agent_id,
                        chat_name=chat_name,
                        kind="cloud",
                        status=status,
                        summary=payload["summary"],
                        workspace=src.get("repository"),
                        ref=src.get("ref"),
                        url=payload["target"]["url"],
                        pr_url=payload["target"].get("prUrl"),
                    )
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
        "kind": "local",
        "chat_name": "测试 Chat",
        "machine": "test-machine",
        "model": "default",
        "summary": "测试消息：机器人已成功上线！",
        "source": {"repository": "测试仓库", "ref": "main"},
        "target": {},
    }
    _remember_agent_detail(
        test_payload["id"],
        chat_name=test_payload["chat_name"],
        kind="local",
        status="FINISHED",
        summary=test_payload["summary"],
        machine=test_payload["machine"],
        model=test_payload["model"],
        workspace=test_payload["source"]["repository"],
        ref="main",
    )
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
