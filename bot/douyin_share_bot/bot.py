"""主循环：监听私信 → 识别分享 → 下载无水印媒体 → 回发给对方。"""
from __future__ import annotations

import json
import logging
import random
import time
from datetime import datetime
from pathlib import Path
from typing import Any

from . import media
from .browser import BrowserError, Conversation, DouyinSession, LoginRequired, Message
from .config import Config, tikhub_key

log = logging.getLogger(__name__)


class State:
    """处理记录：已处理的消息 ID、各会话最后的 sortOrder、频率计数。"""

    def __init__(self, path: Path) -> None:
        self.path = path
        data: dict[str, Any] = {}
        if path.exists():
            try:
                data = json.loads(path.read_text("utf-8"))
            except ValueError:
                log.warning("状态文件损坏，已重新开始：%s", path)
        self.processed: list[str] = data.get("processed", [])
        self.conv_sort: dict[str, str] = data.get("conv_sort", {})
        self.replies: list[float] = data.get("replies", [])
        self.api_calls: dict[str, int] = data.get("api_calls", {})
        self.phone_dirty: bool = data.get("phone_dirty", False)
        self.started_at: float = data.get("started_at") or time.time() * 1000
        self._processed_set = set(self.processed)

    def save(self) -> None:
        self.processed = self.processed[-5000:]
        self._processed_set = set(self.processed)
        today = datetime.now().strftime("%Y-%m-%d")
        self.api_calls = {k: v for k, v in self.api_calls.items() if k >= today}
        data = {"processed": self.processed, "conv_sort": self.conv_sort,
                "replies": [t for t in self.replies if t > time.time() - 3600],
                "api_calls": self.api_calls, "started_at": self.started_at,
                "phone_dirty": self.phone_dirty}
        tmp = self.path.with_suffix(".tmp")
        tmp.write_text(json.dumps(data, ensure_ascii=False, indent=1), "utf-8")
        tmp.replace(self.path)

    def seen(self, message_id: str) -> bool:
        return message_id in self._processed_set

    def mark(self, message_id: str) -> None:
        if message_id not in self._processed_set:
            self.processed.append(message_id)
            self._processed_set.add(message_id)

    def replies_last_hour(self) -> int:
        cutoff = time.time() - 3600
        return sum(1 for t in self.replies if t > cutoff)

    def api_calls_today(self) -> int:
        return self.api_calls.get(datetime.now().strftime("%Y-%m-%d"), 0)

    def count_api_call(self) -> None:
        key = datetime.now().strftime("%Y-%m-%d")
        self.api_calls[key] = self.api_calls.get(key, 0) + 1


class ShareBot:
    def __init__(self, config: Config, session: DouyinSession, dry_run: bool = False, phone: Any = None) -> None:
        self.config = config
        self.phone = phone  # LivePhotoSender，可选
        self.session = session
        self.dry_run = dry_run
        self.state = State(config.state_path)
        self.api_key = tikhub_key()
        self.me = ""

    # ---------- 策略 ----------
    def _quiet_now(self) -> bool:
        start, end = self.config.quiet_start_hour, self.config.quiet_end_hour
        if start == end:
            return False
        hour = datetime.now().hour
        return start <= hour < end if start < end else (hour >= start or hour < end)

    def _allowed(self, conv: Conversation) -> bool:
        allow = self.config.allow_senders
        return not allow or conv.name in allow or conv.direct_id in allow

    # ---------- 主循环 ----------
    def run(self) -> None:
        account = self.session.verify_account()
        self.me = account["identity"]
        log.info("已登录：%s", account["name"])
        self.session.open_inbox()
        first_round = not self.state.conv_sort
        while True:
            try:
                self.tick(first_round)
                first_round = False
            except LoginRequired:
                raise
            except BrowserError as exc:
                log.warning("本轮跳过：%s", exc)
                self._recover()
            except Exception:
                log.exception("本轮出错，稍后重试")
                self._recover()
            self.state.save()
            self.maybe_cleanup_phone()
            time.sleep(self.config.poll_seconds + random.uniform(0, 2))

    def maybe_cleanup_phone(self) -> None:
        """空闲一段时间后，删除手机相册里由 DouyinLite 保存的照片。"""
        if self.phone is None or not self.state.phone_dirty:
            return
        last = max(self.state.replies, default=0)
        if time.time() - last < self.config.phone_cleanup_idle_minutes * 60:
            return
        from .phone import PhoneError
        from .wda import WDAError

        try:
            if not self.phone.available():
                return
            removed = self.phone.cleanup_saved()
            self.state.phone_dirty = False
            self.state.save()
            log.info("空闲清理：已删除手机相册中由抖取保存的 %d 项", removed)
        except (PhoneError, WDAError) as exc:
            log.warning("空闲清理失败，稍后重试：%s", exc)
            self.state.replies.append(time.time())  # 推迟下一次尝试

    def _recover(self) -> None:
        try:
            self.session.page.goto("https://www.douyin.com/jingxuan", wait_until="domcontentloaded")
            self.session.open_inbox()
        except LoginRequired:
            raise
        except Exception:
            log.warning("恢复页面失败，下一轮再试", exc_info=True)

    def tick(self, first_round: bool = False) -> None:
        self.session.open_inbox()
        for conv in self.session.conversations():
            previous = self.state.conv_sort.get(conv.id)
            if previous == conv.sort:
                continue
            if first_round and previous is None:
                # 首次运行：只记录现有会话，不处理历史消息
                self.state.conv_sort[conv.id] = conv.sort
                continue
            if not self._allowed(conv):
                self.state.conv_sort[conv.id] = conv.sort
                continue
            self.handle_conversation(conv)
            self.state.conv_sort[conv.id] = conv.sort
            self.state.save()

    def handle_conversation(self, conv: Conversation) -> None:
        self.session.open_conversation(conv)
        now_ms = time.time() * 1000
        min_created = max(self.state.started_at, now_ms - self.config.max_message_age_minutes * 60_000)
        pending: list[tuple[Message, media.Share]] = []
        for message in self.session.messages():
            if message.sender == self.me or self.state.seen(message.server_id):
                continue
            if message.created_at and message.created_at < min_created:
                self.state.mark(message.server_id)
                continue
            share = media.classify(message.content)
            if share is None:
                self.state.mark(message.server_id)
                continue
            pending.append((message, share))
        pending.sort(key=lambda item: item[0].created_at)
        for message, share in pending:
            if self._quiet_now():
                log.info("静默时段，暂不回复 %s", conv.name)
                return  # 不标记，静默结束后仍在有效期内会继续处理
            if self.state.replies_last_hour() >= self.config.max_replies_per_hour:
                log.warning("已达到每小时回复上限 %d，暂停回复", self.config.max_replies_per_hour)
                return
            # 先标记再发送：宁可漏回，也不因异常重复发送
            self.state.mark(message.server_id)
            self.state.save()
            self.reply(conv, share)

    # ---------- 回复 ----------
    def reply(self, conv: Conversation, share: media.Share) -> None:
        log.info("收到 %s 的%s分享：%s", conv.name, "评论" if share.kind == "comment" else "作品", share.title[:40])
        if share.kind == "aweme" and share.live and self.phone is not None and not self.dry_run:
            if self.reply_live(conv, share):
                return
        work_dir = self.config.media_dir / datetime.now().strftime("%Y%m%d") / f"{share.kind}_{share.comment_id or share.aweme_id}"
        try:
            files = self.prepare_files(share, work_dir)
        except media.MediaError as exc:
            log.warning("无法处理：%s", exc)
            self._reply_text(conv, f"这个分享暂时处理不了：{exc}")
            return
        if not files:
            self._reply_text(conv, "这条评论里没有图片或表情包～" if share.kind == "comment" else "这个作品里没有可下载的内容")
            return
        time.sleep(random.uniform(self.config.reply_delay_min, self.config.reply_delay_max))
        if self.dry_run:
            log.info("[试运行] 将发送给 %s：%s", conv.name, [f.name for f in files])
            return
        self.session.open_conversation(conv)
        sent = 0
        # 网页版一次最多选 9 个文件，分批发送
        for start in range(0, len(files), 9):
            batch = files[start:start + 9]
            timeout = 300 if any(f.suffix == ".mp4" for f in batch) else 90
            sent += self.session.send_files(conv, batch, timeout=timeout)
        self.state.replies.append(time.time())
        if sent < len(files):
            log.warning("给 %s 的回复只确认送达 %d/%d 个文件，请到抖音核对", conv.name, sent, len(files))
        else:
            log.info("已回复 %s：%d 个文件", conv.name, sent)

    def reply_live(self, conv: Conversation, share: media.Share) -> bool:
        """实况作品交给 iPhone：DouyinLite 合成存相册，抖音 App 从相册发送。失败返回 False 改走网页版静态图。"""
        from .phone import PhoneError
        from .wda import WDAError

        if self.state.api_calls_today() >= self.config.max_api_calls_per_day:
            return False
        try:
            if not self.phone.available():
                log.warning("手机未就绪，实况改为发送静态图")
                return False
            self.session.open_conversation(conv)
            before = self.session._own_ids()
            time.sleep(random.uniform(self.config.reply_delay_min, self.config.reply_delay_max))
            self.state.count_api_call()
            self.state.phone_dirty = True
            self.state.save()
            count = self.phone.send_live(share.aweme_id, conv.name)
        except (PhoneError, WDAError) as exc:
            log.warning("手机发送实况失败：%s，改为发送静态图", exc)
            return False
        # 回到网页版核对：对方会话里出现了本账号新发的 count 条消息
        self.session.open_inbox()
        self.session.open_conversation(conv)
        sent = self.session._wait_sent(before, count, 240)
        self.state.replies.append(time.time())
        if sent < count:
            log.warning("手机已发送实况，但网页端只确认到 %d/%d 条，请到抖音核对", sent, count)
        else:
            log.info("已用手机回复 %s：%d 张实况", conv.name, count)
        return True

    def _reply_text(self, conv: Conversation, text: str) -> None:
        if not self.config.reply_text_on_failure or self.dry_run:
            log.info("[不发送文字] %s", text)
            return
        try:
            self.session.open_conversation(conv)
            self.session.send_text(conv, text)
            self.state.replies.append(time.time())
        except BrowserError as exc:
            log.warning("文字回复失败：%s", exc)

    def prepare_files(self, share: media.Share, work_dir: Path) -> list[Path]:
        request = self.session.request
        if share.kind == "comment":
            if not share.image_urls:
                return []
            raw = media.download(request, share.image_urls, work_dir / "comment.bin")
            path = media.finalize_download(raw)
            return [media.make_sendable_image(path)]

        if self.state.api_calls_today() >= self.config.max_api_calls_per_day:
            raise media.MediaError("今天的解析次数已用完，明天再试")
        self.state.count_api_call()
        self.state.save()
        detail = media.fetch_aweme(request, self.api_key, share.aweme_id)
        images = media.image_urls(detail)
        if images:
            files = []
            for index, urls in enumerate(images, 1):
                raw = media.download(request, urls, work_dir / f"{index:02d}.bin")
                files.append(media.make_sendable_image(media.finalize_download(raw)))
            return files
        video = detail.get("video") or {}
        variants = media.video_variants(video)
        if not variants:
            raise media.MediaError("没有找到无水印视频地址")
        limit = self.config.max_video_mb * 1_048_576
        for variant in variants:
            if variant["size"] and variant["size"] > limit:
                continue
            path = media.download(request, variant["urls"], work_dir / "video.bin", max_bytes=limit)
            path = media.finalize_download(path)
            if path.suffix != ".mp4":
                path.unlink(missing_ok=True)
                continue
            return [path]
        raise media.MediaError(f"视频超过 {self.config.max_video_mb} MB，网页私信发不出去")
