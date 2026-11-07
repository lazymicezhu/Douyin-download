"""WebDriverAgent 的最小 HTTP 客户端（直接与手机上的 WDA 通信，不经过 Appium 服务）。"""
from __future__ import annotations

import json
import time
import urllib.error
import urllib.request
from typing import Any


class WDAError(RuntimeError):
    pass


class WDA:
    def __init__(self, base: str = "http://127.0.0.1:8100") -> None:
        self.base = base.rstrip("/")
        self.sid: str | None = None

    # ---------- HTTP ----------
    def _call(self, method: str, path: str, body: Any = None, timeout: float = 60) -> Any:
        data = None if body is None else json.dumps(body).encode()
        request = urllib.request.Request(self.base + path, data=data, method=method,
                                         headers={"Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(request, timeout=timeout) as response:
                payload = json.loads(response.read() or b"{}")
        except urllib.error.HTTPError as exc:
            try:
                payload = json.loads(exc.read() or b"{}")
            except ValueError:
                raise WDAError(f"WDA HTTP {exc.code}") from exc
        except (urllib.error.URLError, TimeoutError, ConnectionError) as exc:
            raise WDAError(f"连不上手机上的 WebDriverAgent：{exc}") from exc
        value = payload.get("value")
        if isinstance(value, dict) and value.get("error"):
            raise WDAError(f"{value.get('error')}: {str(value.get('message'))[:300]}")
        return value

    def _s(self, path: str) -> str:
        if not self.sid:
            raise WDAError("WDA 会话尚未建立")
        return f"/session/{self.sid}{path}"

    # ---------- 会话与应用 ----------
    def ready(self) -> bool:
        try:
            return bool(self._call("GET", "/status", timeout=5).get("ready"))
        except WDAError:
            return False

    def start(self, bundle_id: str | None = None) -> None:
        caps: dict[str, Any] = {"shouldWaitForQuiescence": False}
        if bundle_id:
            caps["bundleId"] = bundle_id
        value = self._call("POST", "/session", {"capabilities": {"alwaysMatch": caps}}, timeout=90)
        self.sid = value.get("sessionId") if isinstance(value, dict) else None
        if not self.sid:
            # 部分版本 sessionId 在顶层
            status = self._call("GET", "/status", timeout=10)
            self.sid = status.get("sessionId") if isinstance(status, dict) else None
        if not self.sid:
            raise WDAError("无法建立 WDA 会话")

    def activate(self, bundle_id: str) -> None:
        self._call("POST", self._s("/wda/apps/activate"), {"bundleId": bundle_id})

    def terminate(self, bundle_id: str) -> None:
        self._call("POST", self._s("/wda/apps/terminate"), {"bundleId": bundle_id})

    def launch(self, bundle_id: str) -> None:
        self._call("POST", self._s("/wda/apps/launch"), {"bundleId": bundle_id, "shouldWaitForQuiescence": False})

    def source(self) -> str:
        return self._call("GET", self._s("/source?format=description"), timeout=60)

    def screenshot_png(self) -> bytes:
        import base64

        return base64.b64decode(self._call("GET", self._s("/screenshot"), timeout=30))

    # ---------- 元素 ----------
    def find_all(self, using: str, value: str) -> list[str]:
        rows = self._call("POST", self._s("/elements"), {"using": using, "value": value})
        return [next(iter(r.values())) for r in rows or []]

    def find(self, using: str, value: str, timeout: float = 10, visible: bool = True) -> str:
        deadline = time.monotonic() + timeout
        while True:
            for element in self.find_all(using, value):
                if not visible or self.attr(element, "visible") in (True, "true", "1"):
                    return element
            if time.monotonic() >= deadline:
                raise WDAError(f"找不到元素：{value}")
            time.sleep(0.5)

    def exists(self, using: str, value: str) -> bool:
        return any(self.attr(e, "visible") in (True, "true", "1") for e in self.find_all(using, value))

    def attr(self, element: str, name: str) -> Any:
        try:
            return self._call("GET", self._s(f"/element/{element}/attribute/{name}"))
        except WDAError:
            return None

    def rect(self, element: str) -> dict[str, float]:
        return self._call("GET", self._s(f"/element/{element}/rect"))

    def click(self, element: str) -> None:
        self._call("POST", self._s(f"/element/{element}/click"), {})

    def type(self, element: str, text: str) -> None:
        self._call("POST", self._s(f"/element/{element}/value"), {"value": list(text)})

    def clear(self, element: str) -> None:
        self._call("POST", self._s(f"/element/{element}/clear"), {})

    def tap(self, x: float, y: float) -> None:
        self._call("POST", self._s("/wda/tap"), {"x": x, "y": y})

    def long_press(self, element: str, seconds: float = 1.0) -> None:
        self._call("POST", self._s(f"/wda/element/{element}/touchAndHold"), {"duration": seconds})

    def swipe(self, direction: str) -> None:
        self._call("POST", self._s("/wda/swipe"), {"direction": direction})

    # ---------- 弹窗与剪贴板 ----------
    def alert_text(self) -> str | None:
        try:
            return self._call("GET", self._s("/alert/text"), timeout=10)
        except WDAError:
            return None

    def alert_buttons(self) -> list[str]:
        try:
            return self._call("GET", self._s("/wda/alert/buttons"), timeout=10) or []
        except WDAError:
            return []

    def alert_click(self, name: str) -> None:
        self._call("POST", self._s("/alert/accept"), {"name": name})

    def set_clipboard(self, text: str) -> None:
        import base64

        self._call("POST", self._s("/wda/setPasteboard"),
                   {"content": base64.b64encode(text.encode()).decode(), "contentType": "plaintext"})
