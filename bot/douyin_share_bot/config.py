from __future__ import annotations

import json
import os
from dataclasses import asdict, dataclass, field, fields
from pathlib import Path

# 与 DouyinFire 相同的做法：登录态、配置、记录都放在本机非同步目录，
# 不放进 iCloud 同步的仓库目录，避免浏览器运行时目录被同步替换。
APP_DIR = Path(os.environ.get("DOUYIN_SHARE_BOT_HOME", Path.home() / "Library/Application Support/DouyinShareBot"))
REPO_ENV = Path(__file__).resolve().parents[2] / ".env"


@dataclass
class Config:
    profile: str = "default"
    # 轮询会话列表的间隔（秒）
    poll_seconds: float = 6.0
    # 回复前随机等待，模拟人工操作（秒）
    reply_delay_min: float = 4.0
    reply_delay_max: float = 12.0
    # 频率上限，超出后本小时内不再回复
    max_replies_per_hour: int = 20
    # 每天最多调用 TikHub 次数（每次约 $0.001）
    max_api_calls_per_day: int = 100
    # 只处理最近多少分钟内收到的消息，避免重启后补发大量旧消息
    max_message_age_minutes: int = 30
    # 夜间静默时段（本地时间，小时）。start == end 表示不静默
    quiet_start_hour: int = 1
    quiet_end_hour: int = 8
    # 只回复这些人（昵称或 secUid）；留空表示回复所有私聊
    allow_senders: list[str] = field(default_factory=list)
    # 单个视频最大体积（MB），过大则改回文字提示
    max_video_mb: int = 200
    # 是否在无法处理时回复一句文字说明
    reply_text_on_failure: bool = True
    # 手机发送实况后，空闲多少分钟再清理相册里由抖取保存的照片
    phone_cleanup_idle_minutes: int = 10

    @property
    def profile_dir(self) -> Path:
        return APP_DIR / "profiles" / self.profile

    @property
    def media_dir(self) -> Path:
        return APP_DIR / "media"

    @property
    def state_path(self) -> Path:
        return APP_DIR / f"state-{self.profile}.json"

    @property
    def log_path(self) -> Path:
        return APP_DIR / "logs" / "bot.log"


CONFIG_PATH = APP_DIR / "config.json"


def load_config() -> Config:
    APP_DIR.mkdir(parents=True, exist_ok=True)
    config = Config()
    if CONFIG_PATH.exists():
        raw = json.loads(CONFIG_PATH.read_text("utf-8"))
        known = {f.name for f in fields(Config)}
        for key, value in raw.items():
            if key in known:
                setattr(config, key, value)
    else:
        CONFIG_PATH.write_text(json.dumps(asdict(config), ensure_ascii=False, indent=2), "utf-8")
    return config


def tikhub_key() -> str:
    """优先环境变量，其次本机配置目录 .env，最后仓库根目录 .env（DouyinLite 共用）。"""
    value = os.environ.get("TIKHUB_API_KEY", "").strip()
    if value:
        return value
    for path in (APP_DIR / ".env", REPO_ENV):
        if not path.exists():
            continue
        for line in path.read_text("utf-8").splitlines():
            name, sep, rest = line.strip().lstrip("﻿").partition("=")
            if sep and name.strip() == "TIKHUB_API_KEY":
                key = rest.strip().strip("\"'")
                if key and key != "your_tikhub_api_key":
                    return key
    raise RuntimeError("没有找到 TIKHUB_API_KEY：请设置环境变量，或写入 ~/Library/Application Support/DouyinShareBot/.env")
