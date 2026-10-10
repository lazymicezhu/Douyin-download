# 抖取 · DouyinLite

[English](README.en.md) · 简体中文

轻量原生 iPhone 抖音下载与数据查询工具。使用 SwiftUI 开发，无第三方依赖，无需自建服务器；通过 TikHub API 获取作品和查询数据。当前应用版本为 **2.1**，界面为简体中文。

## 下载安装

**2.1（Build 3）**：[下载未签名 IPA](https://github.com/lazymicezhu/Douyin-download/releases/download/v2.1/DouyinLite-2.1-unsigned.ipa) · [查看 Release](https://github.com/lazymicezhu/Douyin-download/releases/tag/v2.1)

需要 iPhone **iOS 17+**。IPA 未签名，需使用自己的证书和描述文件签名后安装；TikHub API Key 需自行配置。具体步骤见下方“安装与配置”。

## 功能

- **视频下载**：粘贴分享文案或链接，选择接口实际返回的画质，支持 H.264 / HEVC、保存到相册和导出文件。
- **原画获取**：独立获取原画源。保存到相册时无损重封装并添加全帧率播放标记，保留源分辨率、帧率及音视频样本；也可导出原始文件。该播放标记需要 iOS 18+ 支持，iOS 17 相册可能忽略。
- **图文与实况**：预览和选择图片，复制文案；在本机合成 Live Photo，或保存静图与独立视频。
- **数据查询**：20 个接口，覆盖作者、主页作品、评论、搜索、热榜、音乐、合集、直播、星图达人和关键词趋势；支持手动翻页、复制 ID 与导出 JSON。
- **账户与历史**：查询正常余额及赠送额度，显示平台当日用量，记录本机请求及基于余额变化推算的费用。

画质与内容可用性取决于源作品和 TikHub 返回结果，应用不会提升源文件本身的清晰度，也不会移除作者嵌入画面的文字。

## 前置条件

| 用途 | 条件 |
| --- | --- |
| 构建 | macOS、完整 Xcode 16 或更新版本（含 iOS 18+ SDK）、Python 3；命令行工具须指向该 Xcode |
| 运行 | iPhone，iOS 17 或更新版本 |
| 解析与查询 | 自行准备 [TikHub 账户](https://user.tikhub.io/) 和 API Key；付费接口需要可用余额或适用的赠送额度 |
| 真机安装 | 有效的签名证书及描述文件，或在 Xcode 中配置自己的开发团队 |

应用只使用 Apple 系统框架，无需安装 CocoaPods 或 Swift Package 依赖。构建本身不需要 API Key。

## 获取源码与构建

```sh
git clone https://github.com/lazymicezhu/Douyin-download.git
cd Douyin-download
./scripts/build.sh
```

脚本先重新生成 Xcode 工程，再使用单个编译任务构建设备版，输出 **`dist/DouyinLite-unsigned.ipa`**。构建在临时目录进行，兼容含空格或冒号的源码路径；`build/` 和 `dist/` 是本地产物，不随源码提交。

如需使用 Xcode 调试，打开 `DouyinLite.xcodeproj`，选择 `DouyinLite` scheme，并在 Signing & Capabilities 中设置自己的 Team 和可用的 Bundle Identifier。工程由 `scripts/generate_project.py` 生成，持久的工程设置调整应同步修改生成脚本。

仅构建模拟器版本：

```sh
./scripts/build.sh --simulator
```

输出为 `build/Simulator/DouyinLite.app`，该命令不会启动模拟器。更多构建说明见 [开发指南](docs/development.md)。

## 安装与配置

1. 下载 [Release 中的未签名 IPA](https://github.com/lazymicezhu/Douyin-download/releases/download/v2.1/DouyinLite-2.1-unsigned.ipa)，或按上方步骤自行构建。将 IPA 导入签名工具（如全能签），使用有效证书和描述文件签名后安装；未签名 IPA 不能直接安装，安装有效期由签名决定。也可通过配置好签名的 Xcode 安装到 iPhone。
2. 打开 **抖取 → 账户 → API Key 与配置文件**，手动填写 Key，或复制 Key 后选择“粘贴并保存”。
3. 也可导入包含以下内容的 `.env` / `.txt` 文本文件；支持粘贴整段配置文字，无需手动删除前缀：

```dotenv
TIKHUB_API_KEY=your_tikhub_api_key
```

将示例值替换为自己的 Key。配置只需保存一次，之后存于本机钥匙串；可在应用中更换或移除。

**可选的本地配置**：复制 [.env.example](.env.example) 为项目根目录的 `.env` 并填写密钥后，设备构建脚本会将它复制为 `dist/TikHub.env` 和 `dist/TikHub.txt`，供传到 iPhone 后导入。没有 `.env` 也可正常构建。上述配置文件含私人密钥，已列入忽略规则；它们不会被打包进 IPA。

## 日常使用

1. 在“下载”页粘贴完整分享文案或抖音链接，点击“获取作品”；收费请求会先显示报价，确认后执行。
2. 选择视频画质，或勾选图片及实况保存方式，再保存到相册或导出文件。首次保存会申请添加照片权限。
3. “获取原画”和“链接失效？重新获取”各是一次独立请求，需要重新核对费用；同一会话内相同链接默认复用已有解析结果。

Live Photo 导出为配对的 JPEG 与 MOV；若要直接在 iPhone 相册中显示为实况，请使用“保存到相册”。合成失败时可改为导出独立素材，无需重新解析。临时素材会在切换作品或下次启动时清理，已保存和已导出的文件保留。

## 费用与隐私

- 业务请求前读取接口报价，收费请求须经用户确认；无法取得有效报价时停止。每次确认对应一次请求，不自动重试收费接口，下一页也需要单独确认。
- 报价是美元基础价，折扣与赠送额度可能影响实际扣款，以 TikHub 账单为准。已发送的请求即使取消、失败或未返回可用内容，也可能计费。
- 下载已返回的媒体、切换已有画质、本地合成、保存和导出，不调用付费解析接口。
- 账户余额及当日用量只在核验接口报价为零时刷新；若变为收费或无法定价，自动查询暂停。应用在前台约每 30 秒刷新余额，并对短时间重复查询节流。
- 本机逐笔费用是**余额变化推算**，不是平台逐笔账单；其他客户端并发使用、充值、延迟结算或缺失快照可能使结果待核实。平台当日用量包含同账户其他工具的使用。
- API Key 存于本机钥匙串，只发送到 `api.tikhub.io`；媒体下载不携带此 Key。查询内容会发送至 TikHub，媒体从接口返回的地址下载。
- 请求历史按 Key 的哈希分组，保存在应用本地，不记录密钥、请求参数或完整响应；卸载应用会删除本机历史。导出的 JSON 和媒体由用户自行保存管理。

## 项目结构

```text
Douyin-download/
├── DouyinLite/                 # SwiftUI 页面、下载状态、账户与历史
│   ├── Core/                   # API、解析、媒体下载、Live Photo 与查询目录
│   └── Resources/              # Info.plist 和应用图标
├── DouyinLite.xcodeproj/       # 可重新生成的 Xcode 工程与共享 scheme
├── scripts/
│   ├── build.sh                # 未签名设备包 / 模拟器构建
│   ├── generate_project.py     # 工程生成器
│   ├── make_icon.swift         # 图标生成器
│   └── test.sh                 # 离线核心检查入口
├── tests/                     # Core、Quality、Billing 与 Live Photo 检查
├── docs/                      # 开发、接口与验证记录
├── .editorconfig              # 编辑器格式约定
├── .env.example               # 无密钥的配置模板
├── .gitattributes             # 文本换行与二进制文件规则
├── .gitignore
├── README.md
└── README.en.md
```

## 开发与验证

```sh
./scripts/test.sh
```

默认运行 **CoreTests 的离线检查**，不需要密钥，也不会访问付费接口；它不代表执行了 `tests/` 下的整个测试集。画质、费用和 Live Photo 检查的运行方法见 [开发指南](docs/development.md)。`--live` / `--inspect` 是访问真实 API 的手动模式，会读取本地 `.env`，且可能直接产生费用，不属于常规离线验证。

签名安装、相册导入、Live Photo 展示与高帧率播放仍需真机检查。已有验证结果及待验证项见 [验证记录](docs/verification.md)。

- [开发指南](docs/development.md)
- [查询接口与参数](docs/explore-api.md)
- [费用历史与扣费推算](docs/billing-history-api.md)
- [验证记录](docs/verification.md)
