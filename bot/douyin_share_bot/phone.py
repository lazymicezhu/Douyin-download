"""通过 iPhone 发送实况照片：Mac 经 WebDriverAgent 操作手机上的 DouyinLite 和抖音 App。

流程（均在真机上实际走通）：
1. DouyinLite：填入作品链接 → 解析 → 确认费用 → 选“实况” → 保存到相册
2. 抖音：消息 → 搜索联系人 → 打开私信 → 更多面板 → 勾选最近 N 张 → 原图 → 发送

依赖：go-ios 建立的 RemoteXPC 隧道 + 手机上已安装并由 go-ios 启动的 WebDriverAgent，
端口 8100 转发到本机。见 phone_infra.py。
"""
from __future__ import annotations

import logging
import re
import time
from datetime import datetime

from .wda import WDA, WDAError

log = logging.getLogger(__name__)

DOUYINLITE = "io.lazymice.douyinlite"
DOUYIN = "com.ss.iphone.ugc.Aweme"


def _btn(label: str) -> tuple[str, str]:
    return "predicate string", f"type == 'XCUIElementTypeButton' AND label == '{label}'"


class PhoneError(RuntimeError):
    pass


class LivePhotoSender:
    def __init__(self, wda: WDA | None = None) -> None:
        self.wda = wda or WDA()

    def available(self) -> bool:
        return self.wda.ready()

    def _session(self) -> None:
        if not self.wda.ready():
            raise PhoneError("手机上的 WebDriverAgent 没有运行")
        if not self.wda.sid:
            self.wda.start()

    # ---------- DouyinLite ----------
    def save_live_photos(self, aweme_id: str, timeout: float = 120) -> int:
        """用 DouyinLite 把作品的实况照片存进相册，返回保存的张数。"""
        w = self.wda
        self._session()
        # 每次重启 DouyinLite，保证回到干净的下载页
        try:
            w.terminate(DOUYINLITE)
        except WDAError:
            pass
        w.launch(DOUYINLITE)
        w.click(w.find(*_btn("下载"), timeout=15))
        field = w.find("class name", "XCUIElementTypeTextField", timeout=15)
        if w.exists(*_btn("清空")):
            w.click(w.find(*_btn("清空")))
        w.click(field)
        w.type(field, f"https://www.douyin.com/note/{aweme_id}")
        w.click(w.find("accessibility id", "解析", timeout=10))
        # DouyinLite 2.3+ 正常价格自动解析；旧版本或报价异常时才会出现费用确认
        try:
            w.click(w.find(*_btn("确认并查询"), timeout=4))
        except WDAError:
            pass
        summary = w.find("predicate string", "type == 'XCUIElementTypeStaticText' AND label BEGINSWITH '图文 · '", timeout=60)
        text = w.attr(summary, "label") or ""
        match = re.search(r"(\d+) 张实况", text)
        if not match:
            raise PhoneError(f"这个作品没有实况照片（{text}）")
        if w.exists(*_btn("实况")):
            w.click(w.find(*_btn("实况")))
        save = w.find("predicate string", "type == 'XCUIElementTypeButton' AND label BEGINSWITH '保存' AND label ENDSWITH '到相册'", timeout=10)
        count = int(re.search(r"保存 (\d+) 项", w.attr(save, "label") or "").group(1))
        w.click(save)
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if w.exists("predicate string", "type == 'XCUIElementTypeStaticText' AND label == '已保存到相册'"):
                return count
            alert = w.alert_text()
            if alert:
                raise PhoneError(f"DouyinLite 提示：{alert}")
            time.sleep(1.5)
        raise PhoneError("DouyinLite 保存实况超时")

    # ---------- 抖音 ----------
    def send_recent_photos(self, contact: str, count: int, saved_after: datetime) -> None:
        """在抖音私信里把相册最近 count 张照片（原图、保持实况）发给 contact。"""
        w = self.wda
        self._session()
        # 冷启动抖音回到首页，避免停留在任意页面导致导航不确定
        try:
            w.terminate(DOUYIN)
        except WDAError:
            pass
        w.launch(DOUYIN)
        deadline = time.monotonic() + 30
        while not w.exists(*_btn("消息")):
            if time.monotonic() > deadline:
                raise PhoneError("抖音启动后没有找到“消息”入口")
            # 开屏广告或弹窗
            for label in ("跳过", "关闭", "我知道了", "以后再说"):
                if w.exists("predicate string", f"label == '{label}'"):
                    w.click(w.find("predicate string", f"label == '{label}'"))
            time.sleep(1.5)
        w.click(w.find(*_btn("消息"), timeout=10))
        time.sleep(1.5)
        w.click(w.find(*_btn("搜索"), timeout=10))
        box = w.find("predicate string", "type IN {'XCUIElementTypeTextField','XCUIElementTypeSearchField'}", timeout=10)
        w.type(box, contact)
        time.sleep(2.5)
        matches = [e for e in w.find_all(*_btn(contact)) if w.attr(e, "visible") in (True, "true", "1")]
        if len(matches) != 1:
            raise PhoneError(f"联系人搜索结果里“{contact}”有 {len(matches)} 个，无法确定发送对象")
        w.click(matches[0])
        header = w.find("predicate string", f"type == 'XCUIElementTypeStaticText' AND label == '{contact}'", timeout=10)
        if (w.rect(header) or {}).get("y", 999) > 150:
            raise PhoneError("进入的页面不是与该联系人的私信")
        w.click(w.find(*_btn("更多面板"), timeout=10))
        time.sleep(1.5)
        tiles = w.find_all("predicate string", "type == 'XCUIElementTypeButton' AND label BEGINSWITH '第' AND label CONTAINS '，照片，'")
        boxes = w.find_all(*_btn("复选框"))
        if len(tiles) < count or len(boxes) < count:
            raise PhoneError("最近照片栏里的照片数量不足")
        # 核对最近 count 张都是刚保存的（按分钟精度）
        floor = saved_after.replace(second=0, microsecond=0)
        for tile in tiles[:count]:
            label = w.attr(tile, "label") or ""
            stamp = re.search(r"(\d{4})年(\d{2})月(\d{2})日(\d{2})时(\d{2})分", label)
            if not stamp or datetime(*map(int, stamp.groups())) < floor:
                raise PhoneError(f"最近的照片不是刚保存的实况（{label}），已停止发送")
        for index in range(count):
            w.click(boxes[index])
            time.sleep(0.4)
        original = w.find(*_btn("原图"), timeout=5)
        if w.attr(original, "selected") not in (True, "true", "1"):
            w.click(original)
        w.click(w.find(*_btn("ic s s airplane"), timeout=5))
        time.sleep(3)

    # ---------- 清理 ----------
    def _answer_alert(self, preferred: tuple[str, ...], timeout: float = 8) -> str | None:
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            buttons = self.wda.alert_buttons()
            for name in preferred:
                if name in buttons:
                    self.wda.alert_click(name)
                    return name
            time.sleep(0.5)
        return None

    def cleanup_saved(self) -> int:
        """在 DouyinLite“我的”里清理它自己保存到相册的照片，返回清理前记录的数量。"""
        w = self.wda
        self._session()
        try:
            w.terminate(DOUYINLITE)
        except WDAError:
            pass
        w.launch(DOUYINLITE)
        w.click(w.find(*_btn("我的"), timeout=15))
        button = w.find("predicate string", "type == 'XCUIElementTypeButton' AND label BEGINSWITH '清理已保存的照片'", timeout=10)
        match = re.search(r"(\d+) 项", w.attr(button, "label") or "")
        pending = int(match.group(1)) if match else 0
        if pending == 0 or w.attr(button, "enabled") in (False, "false", "0"):
            return 0
        w.click(button)
        # 首次清理需要“完全访问”相册权限，随后系统确认删除
        self._answer_alert(("允许完全访问", "Allow Full Access"), timeout=4)
        if self._answer_alert(("删除", "Delete"), timeout=15) is None:
            raise PhoneError("没有出现系统删除确认，清理未完成")
        deadline = time.monotonic() + 20
        while time.monotonic() < deadline:
            if w.exists("predicate string", "type == 'XCUIElementTypeButton' AND label BEGINSWITH '清理已保存的照片' AND label CONTAINS '0 项'"):
                return pending
            time.sleep(1)
        raise PhoneError("清理后记录未归零，请到手机上核对")

    def send_live(self, aweme_id: str, contact: str) -> int:
        started = datetime.now()
        count = self.save_live_photos(aweme_id)
        self.send_recent_photos(contact, count, started)
        return count
