# 抖音私信分享自动回复机器人（MVP）

在 Mac 上用抖音网页版登录一个小号，常驻监听私信：

- 别人**分享作品**给小号 → 回复无水印视频（图文作品回复全部图片）
- 别人**分享评论**给小号 → 回复评论里的原图 / 表情包（webp 动图自动转 GIF）

登录态做法与 DouyinFire 相同：独立的 Playwright Chromium 配置目录，首次可见窗口扫码，之后无界面运行。

## 安装

```bash
cd bot
python3 -m pip install -r requirements.txt
python3 -m playwright install chromium
```

TikHub Key 读取顺序：环境变量 `TIKHUB_API_KEY` → `~/Library/Application Support/DouyinShareBot/.env` → 仓库根目录 `.env`（与 DouyinLite 共用）。

## 使用

```bash
python3 -m douyin_share_bot login        # 弹出窗口，用小号扫码
python3 -m douyin_share_bot check        # 检查登录是否有效
python3 -m douyin_share_bot run          # 无界面运行；加 --show 显示窗口，--dry-run 只下载不发送
python3 -m douyin_share_bot paths        # 查看配置、日志、下载目录
```

首次 `run` 只登记现有会话，不处理历史消息。

## 配置

`~/Library/Application Support/DouyinShareBot/config.json`（首次运行自动生成）：

| 字段 | 默认 | 说明 |
| --- | --- | --- |
| `poll_seconds` | 6 | 检查会话列表的间隔 |
| `reply_delay_min/max` | 4 / 12 | 回复前随机等待（秒） |
| `max_replies_per_hour` | 20 | 每小时回复上限 |
| `max_api_calls_per_day` | 100 | 每天 TikHub 调用上限（每次约 $0.001；评论图片不调用 TikHub） |
| `max_message_age_minutes` | 30 | 只处理这么久以内的消息 |
| `quiet_start_hour/quiet_end_hour` | 1 / 8 | 夜间静默时段，相同则关闭 |
| `allow_senders` | `[]` | 只回复这些昵称或 secUid，空为全部私聊 |
| `max_video_mb` | 200 | 视频体积上限 |
| `reply_text_on_failure` | true | 处理失败时回复一句文字 |

## 实况照片（可选，需要一台 iPhone）

网页版私信无法发送实况，所以实况作品交给数据线连接的 iPhone：
DouyinLite（2.4+）解析并保存实况到相册 → 抖音 App 私信从相册勾选“原图”发送 → 网页端核对已送达。
空闲 `phone_cleanup_idle_minutes` 分钟后，机器人在 DouyinLite“我的”里点“清理已保存的照片”，只删除抖取自己保存的项目。

闲置手机准备：

1. 关闭 iCloud 照片；抖音 App 登录机器人小号；安装 DouyinLite 2.4 并导入 TikHub Key
2. 设置 → 隐私与安全性 → 开发者模式 打开；数据线连接 Mac 并信任
3. 用全能签安装 `dist/WebDriverAgentRunner.ipa`（Bundle ID 保持 `com.facebook.WebDriverAgentRunner.xctrunner`）
4. Mac 上已有 go-ios（`~/.douyin-bot/ios`），运行时会自动建隧道、启动 WebDriverAgent

```bash
python3 -m douyin_share_bot run --phone
```

手机不可用或发送失败时，实况作品自动改用网页版发送静态图。删除的照片会进入“最近删除”，30 天后系统自动清除。

## 注意

- 自动收发私信违反抖音用户协议，只用小号，保持低频。
- 出现验证码或登录失效时程序会停止，重新运行 `login` 完成人工验证。
- 为避免重复发送，消息在发送前就记为已处理；发送中断的消息不会自动重发。
- 只处理私聊，不处理群聊。
