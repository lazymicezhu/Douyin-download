"""启动手机端自动化基础设施：go-ios 用户态隧道 → WebDriverAgent → 8100 端口转发。

iOS 17+ 启动测试程序需要 RemoteXPC 隧道。go-ios 的用户态隧道无需 sudo；
WebDriverAgentRunner 由用户自行签名安装（全能签开发证书可用），这里只负责启动。
"""
from __future__ import annotations

import json
import logging
import os
import subprocess
import time
import urllib.request
from pathlib import Path

from .config import APP_DIR
from .wda import WDA

log = logging.getLogger(__name__)

GO_IOS = Path(os.environ.get("GO_IOS", Path.home() / ".douyin-bot/ios"))
# go-ios 会在工作目录写入配对身份 selfIdentity.plist（含私钥），固定放在仓库与 iCloud 之外
GO_IOS_DATA = Path.home() / ".douyin-bot/goios-data"
WDA_BUNDLE = "com.facebook.WebDriverAgentRunner.xctrunner"
TUNNEL_API = "http://127.0.0.1:60105/tunnels"


class PhoneInfra:
    def __init__(self, udid: str = "") -> None:
        self.udid = udid
        self.procs: list[subprocess.Popen] = []
        self.log_dir = APP_DIR / "logs"
        self.log_dir.mkdir(parents=True, exist_ok=True)

    def _spawn(self, name: str, *args: str) -> subprocess.Popen:
        handle = open(self.log_dir / f"{name}.log", "ab")
        GO_IOS_DATA.mkdir(parents=True, exist_ok=True)
        proc = subprocess.Popen([str(GO_IOS), *args], stdout=handle, stderr=subprocess.STDOUT, cwd=GO_IOS_DATA)
        self.procs.append(proc)
        return proc

    def _tunnel(self) -> dict | None:
        try:
            with urllib.request.urlopen(TUNNEL_API, timeout=3) as response:
                rows = json.loads(response.read() or b"[]")
        except Exception:
            return None
        rows = [r for r in rows or [] if not self.udid or r.get("udid") == self.udid]
        return rows[0] if rows else None

    def start(self, timeout: float = 90) -> WDA:
        wda = WDA()
        if wda.ready():
            log.info("WebDriverAgent 已在运行")
            return wda
        if not GO_IOS.exists():
            raise RuntimeError(f"没有找到 go-ios：{GO_IOS}")
        if self._tunnel() is None:
            self._spawn("tunnel", "tunnel", "start", "--userspace")
        deadline = time.monotonic() + 30
        tunnel = None
        while time.monotonic() < deadline and tunnel is None:
            time.sleep(1)
            tunnel = self._tunnel()
        if tunnel is None:
            raise RuntimeError("无法与 iPhone 建立隧道：确认手机已用数据线连接、已解锁并信任此电脑")
        self.udid = tunnel["udid"]
        common = [f"--udid={tunnel['udid']}", f"--address={tunnel['address']}",
                  f"--rsd-port={tunnel['rsdPort']}", f"--userspace-port={tunnel['userspaceTunPort']}"]
        self._spawn("wda", "runwda", f"--bundleid={WDA_BUNDLE}", f"--testrunnerbundleid={WDA_BUNDLE}",
                    "--xctestconfig=WebDriverAgentRunner.xctest", *common)
        time.sleep(5)
        self._spawn("forward", "forward", "8100", "8100", *common)
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if wda.ready():
                log.info("WebDriverAgent 已就绪（%s）", self.udid)
                return wda
            time.sleep(2)
        raise RuntimeError("WebDriverAgent 启动超时：确认手机上已安装签名的 WebDriverAgentRunner，且证书未过期")

    def stop(self) -> None:
        for proc in reversed(self.procs):
            proc.terminate()
        self.procs.clear()
