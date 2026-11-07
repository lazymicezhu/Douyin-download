"""解析分享内容、下载无水印媒体，并转换成网页版私信能发送的格式。"""
from __future__ import annotations

import io
import logging
import re
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

log = logging.getLogger(__name__)

TIKHUB_VIDEO = "https://api.tikhub.io/api/v1/douyin/web/fetch_one_video"
REFERER = {"Referer": "https://www.douyin.com/"}
# 网页版私信上传控件 accept=".jpg,.jpeg,.png,.gif,.mp4"
SENDABLE = {".jpg", ".jpeg", ".png", ".gif", ".mp4"}


class MediaError(RuntimeError):
    """可以用一句话回复给对方的处理失败。"""


@dataclass
class Share:
    kind: str  # "aweme" 分享作品 / "comment" 分享评论
    aweme_id: str = ""
    comment_id: str = ""
    image_urls: list[str] = field(default_factory=list)
    title: str = ""
    live: bool = False


def classify(content: dict[str, Any]) -> Share | None:
    """根据网页私信 parsedContent 判断消息类型；不认识的消息返回 None。"""
    awe_type = content.get("aweType")
    if awe_type == 10500 or content.get("comment_id"):
        urls = ((content.get("comment_url") or {}).get("url_list")) or []
        return Share(kind="comment", aweme_id=str(content.get("itemId") or ""),
                     comment_id=str(content.get("comment_id") or ""),
                     image_urls=[u for u in urls if isinstance(u, str)],
                     title=str(content.get("comment") or ""))
    item_id = content.get("itemId")
    # 观察到：视频分享 aweType=800；图文分享 awemeType=68。两者都带 itemId 和 content_title。
    if item_id and re.fullmatch(r"\d{6,30}", str(item_id)) and "content_title" in content:
        return Share(kind="aweme", aweme_id=str(item_id), title=str(content.get("content_title") or ""),
                     live=str(content.get("is_live_photo")) == "1")
    return None


# ---------- TikHub ----------
def fetch_aweme(request: Any, api_key: str, aweme_id: str) -> dict[str, Any]:
    response = request.get(TIKHUB_VIDEO, params={"aweme_id": aweme_id},
                           headers={"Authorization": f"Bearer {api_key}", "Accept": "application/json"},
                           timeout=60_000, max_redirects=0)
    if response.status == 401:
        raise RuntimeError("TikHub API Key 无效")
    if response.status == 402:
        raise RuntimeError("TikHub 余额不足")
    if not response.ok:
        raise MediaError(f"解析作品失败（HTTP {response.status}）")
    root = response.json()
    if root.get("code") not in (200, 0, None):
        raise MediaError("解析作品失败，作品可能已删除或设为私密")
    data = root.get("data") or {}
    detail = data.get("aweme_detail") or (data.get("aweme_details") or [None])[0] or (data if data.get("aweme_id") else None)
    if not detail:
        raise MediaError("作品已删除、私密或暂时无法访问")
    return detail


def _url_list(address: Any) -> list[str]:
    if not isinstance(address, dict):
        return []
    return [u for u in address.get("url_list") or [] if isinstance(u, str) and u.startswith("http")]


def _positive(value: Any) -> int:
    try:
        number = int(value)
    except (TypeError, ValueError):
        return 0
    return number if number > 0 else 0


def video_variants(video: dict[str, Any]) -> list[dict[str, Any]]:
    """与 DouyinLite 相同：只用 play_addr*，不用可能带水印的 download_addr。"""
    variants = []

    def collect(meta: dict[str, Any]) -> None:
        for key, address in meta.items():
            if not (key == "play_addr" or key.startswith("play_addr_")):
                continue
            urls = _url_list(address)
            if not urls:
                continue
            hint = f"{meta.get('codec') or ''} {meta.get('gear_name') or ''} {address.get('url_key') or ''} {key}".lower()
            hevc = bool(_positive(meta.get("is_h265")) or _positive(meta.get("is_bytevc1"))
                        or any(t in hint for t in ("h265", "hevc", "bytevc1", "play_addr_265")))
            variants.append({
                "urls": urls, "hevc": hevc,
                "pixels": _positive(address.get("width") or meta.get("width")) * _positive(address.get("height") or meta.get("height")),
                "bitrate": _positive(meta.get("bit_rate")),
                "size": _positive(address.get("data_size")),
            })

    for rate in video.get("bit_rate") or []:
        if isinstance(rate, dict):
            collect(rate)
    collect(video)
    # 优先 H.264（手机端兼容最好），再按分辨率、码率从高到低
    variants.sort(key=lambda v: (v["hevc"], -v["pixels"], -v["bitrate"]))
    return variants


def image_urls(detail: dict[str, Any]) -> list[list[str]]:
    images = detail.get("images") or ((detail.get("image_post_info") or {}).get("images")) or []
    result = []
    for item in images:
        urls = _url_list(item) or _url_list((item or {}).get("display_image"))
        if urls:
            # 同一张图通常同时给出 webp 和 jpeg 两种地址，优先 jpeg
            urls.sort(key=lambda u: (".webp" in u.lower() or "webp" in u.lower().split("?")[0]))
            result.append(urls)
    return result


# ---------- 下载与格式转换 ----------
def download(request: Any, urls: list[str], dest: Path, max_bytes: int | None = None) -> Path:
    last = ""
    for url in urls:
        try:
            response = request.get(url, headers=REFERER, timeout=120_000)
        except Exception as exc:  # 网络错误换下一个 CDN
            last = str(exc)
            continue
        if not response.ok:
            last = f"HTTP {response.status}"
            continue
        body = response.body()
        if max_bytes and len(body) > max_bytes:
            raise MediaError(f"文件太大（{len(body) // 1_048_576} MB），网页私信发不出去")
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_bytes(body)
        return dest
    raise MediaError(f"下载失败：{last or '没有可用地址'}")


def make_sendable_image(path: Path) -> Path:
    """把下载的图片转成私信可发送的格式：动图→gif，静图 webp/heic 等→png/jpg。"""
    from PIL import Image

    with Image.open(path) as image:
        fmt = (image.format or "").upper()
        animated = getattr(image, "is_animated", False) and getattr(image, "n_frames", 1) > 1
        if fmt in {"JPEG", "PNG"} and not animated:
            target = path.with_suffix(".jpg" if fmt == "JPEG" else ".png")
        elif fmt == "GIF":
            target = path.with_suffix(".gif")
        else:
            target = None
        if target is not None:
            if target != path:
                path.rename(target)
            return target
        if animated:
            target = path.with_suffix(".gif")
            frames, durations = [], []
            for index in range(image.n_frames):
                image.seek(index)
                frames.append(image.convert("RGBA"))
                durations.append(image.info.get("duration", 80) or 80)
            frames[0].save(target, save_all=True, append_images=frames[1:], duration=durations,
                           loop=0, disposal=2, optimize=False)
        else:
            has_alpha = image.mode in ("RGBA", "LA") or "transparency" in image.info
            target = path.with_suffix(".png" if has_alpha else ".jpg")
            converted = image.convert("RGBA" if has_alpha else "RGB")
            converted.save(target, **({} if has_alpha else {"quality": 95}))
    path.unlink(missing_ok=True)
    return target


def sniff_suffix(data_head: bytes) -> str:
    if data_head.startswith(b"\x89PNG"):
        return ".png"
    if data_head[:3] == b"\xff\xd8\xff":
        return ".jpg"
    if data_head[:6] in (b"GIF87a", b"GIF89a"):
        return ".gif"
    if data_head[:4] == b"RIFF" and data_head[8:12] == b"WEBP":
        return ".webp"
    if data_head[4:8] == b"ftyp":
        return ".mp4"
    return ".bin"


def finalize_download(path: Path) -> Path:
    with path.open("rb") as handle:
        suffix = sniff_suffix(handle.read(16))
    target = path.with_suffix(suffix)
    if target != path:
        path.rename(target)
    return target


def image_bytes_ok(path: Path) -> bool:
    try:
        from PIL import Image

        with Image.open(io.BytesIO(path.read_bytes())) as image:
            image.verify()
        return True
    except Exception:
        return False
