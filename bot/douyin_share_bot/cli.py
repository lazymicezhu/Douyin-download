from __future__ import annotations

import argparse
import logging
import sys

from .browser import DouyinSession, LoginRequired
from .config import APP_DIR, CONFIG_PATH, load_config


def _setup_logging(path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(message)s",
        datefmt="%m-%d %H:%M:%S",
        handlers=[logging.StreamHandler(sys.stdout), logging.FileHandler(path, encoding="utf-8")],
    )


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="douyin_share_bot", description="抖音私信分享自动回复机器人")
    sub = parser.add_subparsers(dest="command", required=True)
    login = sub.add_parser("login", help="打开可见浏览器窗口扫码登录（或完成人工验证）")
    login.add_argument("--wait", type=int, default=300, help="等待扫码的秒数")
    sub.add_parser("check", help="检查登录状态")
    run = sub.add_parser("run", help="开始监听私信并自动回复")
    run.add_argument("--show", action="store_true", help="显示浏览器窗口（默认无界面运行）")
    run.add_argument("--dry-run", action="store_true", help="只下载和记录，不实际发送")
    run.add_argument("--phone", action="store_true", help="启用 iPhone 发送实况照片（需数据线连接并安装 WebDriverAgent）")
    sub.add_parser("paths", help="显示配置与数据目录")
    args = parser.parse_args(argv)

    config = load_config()
    _setup_logging(config.log_path)
    log = logging.getLogger("douyin_share_bot")

    if args.command == "paths":
        print(f"数据目录：{APP_DIR}\n配置文件：{CONFIG_PATH}\n登录目录：{config.profile_dir}\n媒体目录：{config.media_dir}\n日志：{config.log_path}")
        return 0
    try:
        if args.command == "login":
            with DouyinSession(config.profile_dir, headless=False) as session:
                print("请在弹出的浏览器窗口中用机器人小号扫码登录…")
                account = session.login(args.wait)
                print(f"登录成功：{account['name']}（{account['identity']}）")
            return 0
        if args.command == "check":
            with DouyinSession(config.profile_dir, headless=True) as session:
                account = session.verify_account()
                print(f"登录有效：{account['name']}")
            return 0
        if args.command == "run":
            from .bot import ShareBot

            phone, infra = None, None
            if args.phone:
                from .phone import LivePhotoSender
                from .phone_infra import PhoneInfra

                infra = PhoneInfra()
                phone = LivePhotoSender(infra.start())
            try:
                with DouyinSession(config.profile_dir, headless=not args.show) as session:
                    ShareBot(config, session, dry_run=args.dry_run, phone=phone).run()
            finally:
                if infra is not None:
                    infra.stop()
            return 0
    except LoginRequired as exc:
        log.error("%s", exc)
        return 2
    except KeyboardInterrupt:
        log.info("已停止")
        return 0
    return 1
