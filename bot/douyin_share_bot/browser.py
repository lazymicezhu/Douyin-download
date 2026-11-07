"""抖音网页版会话与私信操作。

登录态的做法沿用 DouyinFire：每个账号一个 Playwright 持久化 Chromium 配置目录，
首次在可见窗口扫码登录，之后无界面运行；账号身份以页面 RENDER_DATA 中的 secUid 为准。
页面字段均在已登录的 douyin.com 上实际观察得到，页面结构变化时宁可停止也不误发。
"""
from __future__ import annotations

import json
import logging
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any
from urllib.parse import unquote

log = logging.getLogger(__name__)

HOME_URL = "https://www.douyin.com/jingxuan"
SELF_URL = "https://www.douyin.com/user/self"

DIALOG = "[data-e2e='im-dialog']"
IM_ENTRY = "[data-e2e='im-entry'] [data-e2e='something-button']"
CONV_ITEM = "[data-e2e='conversation-item']"
HEADER = DIALOG + " .StackLayoutStackChatHeaderuser"
MSG_BOX = DIALOG + " .messageMessageBoxmessageBox"
EDITOR = DIALOG + " [data-e2e='msg-input'] [contenteditable='true'][data-slate-editor]"
SEND_BTN = DIALOG + " [data-e2e='msg-input'] .e2e-send-msg-btn"
FILE_INPUT = DIALOG + " input.semi-upload-hidden-input"
FILE_MODAL_SURE = ".semi-modal-wrap button.MsgInputSendFileModalbtnSure"
FILE_MODAL_RECEIVER = ".semi-modal-wrap .MsgInputSendFileModalreceiver"

_CONVERSATIONS_JS = """els => els.map(e => {
    const key = Object.keys(e).find(k => k.startsWith('__reactProps'));
    const c = e[key]?.children?.[0]?.props?.children?.props?.conversation;
    if (!c) return null;
    const names = e.querySelectorAll('.conversationConversationItemtitle');
    return {type: c.type, id: c.id, direct_id: c.toParticipantSecUserId ?? null,
            sort: c.sortOrder != null ? String(c.sortOrder) : null,
            name: names.length === 1 ? names[0].innerText.trim() : null};
})"""

_HEADER_JS = """e => {
    const key = Object.keys(e).find(k => k.startsWith('__reactProps'));
    const c = e[key]?.children?.[0]?.props?.conversation;
    return c ? {type: c.type, id: c.id, direct_id: c.toParticipantSecUserId ?? null} : null;
}"""

# 消息对象挂在消息气泡的 React 子树里；按 serverId 字段识别，不依赖固定层级。
_MESSAGES_JS = """els => els.map(e => {
    const fk = Object.keys(e).find(k => k.startsWith('__reactFiber'));
    let m = null;
    function walk(f, d) {
        if (!f || d > 40 || m) return;
        const p = f.memoizedProps;
        if (p && p.message && typeof p.message === 'object' && p.message.serverId !== undefined) { m = p.message; return; }
        walk(f.child, d + 1); walk(f.sibling, d + 1);
    }
    walk(e[fk]?.child, 0);
    if (!m) return null;
    let content = null;
    try { content = JSON.parse(JSON.stringify(m.parsedContent ?? null)); } catch (err) { content = null; }
    return {
        server_id: m.serverId != null ? String(m.serverId) : null,
        client_id: m.clientId != null ? String(m.clientId) : null,
        status: typeof m.serverStatus === 'number' ? m.serverStatus : null,
        sender: typeof m.secSender === 'string' ? m.secSender : null,
        conversation_id: typeof m.conversationId === 'string' ? m.conversationId : null,
        type: typeof m.type === 'number' ? m.type : null,
        created_at: m.createdAt instanceof Date ? m.createdAt.getTime() : null,
        content
    };
})"""


class BrowserError(RuntimeError):
    pass


class LoginRequired(BrowserError):
    pass


@dataclass
class Conversation:
    id: str
    direct_id: str
    name: str
    sort: str


@dataclass
class Message:
    server_id: str
    client_id: str
    status: int | None
    sender: str
    conversation_id: str
    type: int | None
    created_at: float
    content: dict[str, Any]


def verification_required(page: Any) -> bool:
    title = (page.title() or "").strip().lower()
    if any(marker in title for marker in ("验证码中间页", "安全验证", "人机验证", "captcha")):
        return True
    frames = page.locator("iframe[src]")
    for index in range(min(frames.count(), 30)):
        frame = frames.nth(index)
        if not frame.is_visible():
            continue
        source = (frame.get_attribute("src", timeout=1000) or "").lower()
        label = (frame.get_attribute("title", timeout=1000) or "").lower()
        if "captcha" in source or any(marker in label for marker in ("验证码", "安全验证", "captcha")):
            return True
    return False


def safe_click(locator: Any) -> None:
    """抖音会不定期弹出“下载客户端”等浮层盖住按钮；被遮挡时直接向目标派发点击事件。"""
    try:
        locator.click(timeout=2500)
    except Exception as exc:
        if "intercepts pointer events" not in str(exc) and "Timeout" not in type(exc).__name__:
            raise
        locator.dispatch_event("click")


class DouyinSession:
    def __init__(self, profile_dir: Path, headless: bool) -> None:
        self.profile_dir = Path(profile_dir)
        self.headless = headless
        self._pw: Any = None
        self.context: Any = None
        self.page: Any = None
        self.account: dict[str, str] | None = None

    # ---------- 生命周期 ----------
    def __enter__(self) -> "DouyinSession":
        from playwright.sync_api import sync_playwright

        self.profile_dir.mkdir(parents=True, exist_ok=True)
        self._pw = sync_playwright().start()
        try:
            self.context = self._pw.chromium.launch_persistent_context(
                user_data_dir=str(self.profile_dir),
                channel="chromium",
                headless=self.headless,
                viewport={"width": 1440, "height": 1000},
                timeout=30_000,
            )
        except Exception:
            self._pw.stop()
            raise
        self.page = self.context.pages[0] if self.context.pages else self.context.new_page()
        self.page.set_default_timeout(5000)
        self.page.set_default_navigation_timeout(20_000)
        return self

    def __exit__(self, *exc: Any) -> None:
        for obj, method in ((self.context, "close"), (self._pw, "stop")):
            try:
                if obj is not None:
                    getattr(obj, method)()
            except Exception:
                log.warning("关闭浏览器时出错", exc_info=True)
        self.context = self._pw = self.page = None

    @property
    def request(self) -> Any:
        """复用浏览器所在的网络环境下载媒体、调用 TikHub。"""
        return self.context.request

    # ---------- 账号 ----------
    def _rendered_account(self) -> dict[str, str] | None:
        scripts = self.page.locator("script#RENDER_DATA[type='application/json']")
        if scripts.count() != 1:
            return None
        try:
            data = json.loads(unquote(scripts.first.text_content(timeout=2000) or ""))
            user = data["app"]["user"]
            if user.get("isLogin") is not True:
                return None
            info = user["info"]
            if not info.get("secUid") or not info.get("nickname"):
                return None
            return {"identity": info["secUid"], "name": info["nickname"].strip()}
        except (KeyError, TypeError, ValueError):
            return None

    def has_session_cookie(self) -> bool:
        cookies = self.context.cookies("https://www.douyin.com")
        return any(c["name"] in ("sessionid", "sessionid_ss") and c["value"] for c in cookies)

    def verify_account(self) -> dict[str, str]:
        if not self.has_session_cookie():
            raise LoginRequired("尚未登录，请先运行 login 扫码登录。")
        self.page.goto(SELF_URL, wait_until="domcontentloaded")
        deadline = time.monotonic() + 20
        while time.monotonic() < deadline:
            if verification_required(self.page):
                raise LoginRequired("抖音要求人工验证，请运行 login 在可见窗口完成验证。")
            account = self._rendered_account()
            if account:
                self.account = account
                return account
            self.page.wait_for_timeout(500)
        raise LoginRequired("登录已失效，请重新运行 login 扫码登录。")

    def login(self, wait_seconds: int = 300) -> dict[str, str]:
        self.page.goto(HOME_URL, wait_until="domcontentloaded")
        deadline = time.monotonic() + wait_seconds
        while time.monotonic() < deadline:
            if self.has_session_cookie():
                self.page.wait_for_timeout(2000)
                return self.verify_account()
            self.page.wait_for_timeout(1000)
        raise LoginRequired("等待扫码登录超时。")

    # ---------- 会话列表 ----------
    def open_inbox(self) -> None:
        if self.page.locator(DIALOG).count() and self.page.locator(DIALOG).first.is_visible():
            return
        if "douyin.com" not in self.page.url or "/user/" in self.page.url:
            self.page.goto(HOME_URL, wait_until="domcontentloaded")
        if verification_required(self.page):
            raise LoginRequired("抖音要求人工验证，请运行 login 在可见窗口完成验证。")
        entry = self.page.locator(IM_ENTRY).first
        entry.wait_for(state="visible", timeout=20_000)
        # SSR 按钮先于点击处理器出现，稍等页面水合
        self.page.wait_for_timeout(1500)
        safe_click(entry)
        self.page.locator(CONV_ITEM).first.wait_for(state="visible", timeout=20_000)

    def conversations(self) -> list[Conversation]:
        rows = self.page.locator(CONV_ITEM).evaluate_all(_CONVERSATIONS_JS)
        result = []
        for row in rows:
            # 只处理私聊（type 1）
            if not isinstance(row, dict) or row.get("type") != 1 or not row.get("direct_id"):
                continue
            result.append(Conversation(id=row["id"], direct_id=row["direct_id"],
                                       name=row.get("name") or "", sort=row.get("sort") or ""))
        return result

    def _current_header(self) -> dict[str, Any] | None:
        header = self.page.locator(HEADER)
        if header.count() != 1 or not header.first.is_visible():
            return None
        return header.first.evaluate(_HEADER_JS)

    def open_conversation(self, conv: Conversation) -> None:
        current = self._current_header()
        if current and current.get("id") == conv.id:
            return
        items = self.page.locator(CONV_ITEM)
        target = None
        for index in range(items.count()):
            row = items.nth(index).evaluate(
                "e => { const k = Object.keys(e).find(k => k.startsWith('__reactProps'));"
                " return e[k]?.children?.[0]?.props?.children?.props?.conversation?.id ?? null; }")
            if row == conv.id:
                target = items.nth(index)
                break
        if target is None:
            raise BrowserError(f"会话列表里找不到 {conv.name}")
        safe_click(target)
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            current = self._current_header()
            if current and current.get("id") == conv.id and current.get("direct_id") == conv.direct_id:
                self.page.locator(MSG_BOX).first.wait_for(state="attached", timeout=10_000)
                self.page.wait_for_timeout(800)
                return
            self.page.wait_for_timeout(250)
        raise BrowserError(f"打开会话 {conv.name} 后无法核对对方身份，已跳过。")

    def messages(self) -> list[Message]:
        rows = self.page.locator(MSG_BOX).evaluate_all(_MESSAGES_JS)
        result = []
        for row in rows:
            if not isinstance(row, dict) or not row.get("server_id") or not row.get("sender"):
                continue
            result.append(Message(
                server_id=row["server_id"], client_id=row.get("client_id") or "",
                status=row.get("status"), sender=row["sender"],
                conversation_id=row.get("conversation_id") or "", type=row.get("type"),
                created_at=float(row.get("created_at") or 0), content=row.get("content") or {},
            ))
        return result

    # ---------- 发送 ----------
    def _assert_conversation(self, conv: Conversation) -> None:
        current = self._current_header()
        if not current or current.get("id") != conv.id or current.get("direct_id") != conv.direct_id:
            raise BrowserError("发送前聊天对象发生变化，已停止发送。")

    def _own_ids(self) -> set[str]:
        me = self.account["identity"] if self.account else ""
        return {m.server_id for m in self.messages() if m.sender == me}

    def _wait_sent(self, before: set[str], expected: int, timeout: float) -> int:
        me = self.account["identity"] if self.account else ""
        deadline = time.monotonic() + timeout
        confirmed = 0
        while time.monotonic() < deadline:
            new = [m for m in self.messages()
                   if m.sender == me and m.server_id not in before and m.server_id.isdigit() and m.status == 0]
            confirmed = len(new)
            if confirmed >= expected:
                return confirmed
            self.page.wait_for_timeout(1000)
        return confirmed

    def send_files(self, conv: Conversation, files: list[Path], timeout: float = 180) -> int:
        """通过私信输入框的上传按钮发送图片/视频（网页版接受 jpg/png/gif/mp4）。"""
        self._assert_conversation(conv)
        before = self._own_ids()
        self.page.locator(FILE_INPUT).first.set_input_files([str(f) for f in files])
        receiver = self.page.locator(FILE_MODAL_RECEIVER).first
        receiver.wait_for(state="visible", timeout=15_000)
        if conv.name and conv.name not in receiver.inner_text():
            self.page.locator(".semi-modal-wrap button.MsgInputSendFileModalbtnCancle").first.click()
            raise BrowserError("发送确认框里的收件人与当前会话不一致，已取消。")
        self._assert_conversation(conv)
        safe_click(self.page.locator(FILE_MODAL_SURE).first)
        return self._wait_sent(before, len(files), timeout)

    def send_text(self, conv: Conversation, text: str) -> bool:
        self._assert_conversation(conv)
        editor = self.page.locator(EDITOR).first
        existing = (editor.inner_text() or "").replace("​", "").replace("﻿", "").strip()
        if existing:
            raise BrowserError("输入框里有未发送的草稿，避免覆盖，已跳过文字回复。")
        before = self._own_ids()
        editor.fill(text)
        button = self.page.locator(SEND_BTN).first
        button.wait_for(state="visible", timeout=5000)
        safe_click(button)
        return self._wait_sent(before, 1, 20) >= 1
