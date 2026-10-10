# 开发指南 / Development guide

[中文 README](../README.md) · [English README](../README.en.md)

## 环境 / Requirements

- macOS、完整 Xcode（含 iOS 18 或更新 SDK）及 Python 3。运行设备最低 iOS 17；源码使用 Swift 5 语言模式，无第三方依赖。
- macOS, full Xcode with an iOS 18 or newer SDK, and Python 3. The deployment target is iOS 17; the project uses Swift 5 language mode and has no third-party dependencies.
- 最近本地构建环境为 Xcode 26.4；最低可用 Xcode 版本未单独验证。
- The existing local build environment is Xcode 26.4; the oldest compatible Xcode version has not been independently tested.

## 目录职责 / Source map

| 路径 / Path | 职责 / Responsibility |
| --- | --- |
| `DouyinLite/DouyinLiteApp.swift` | 应用入口 / App entry point |
| `DouyinLite/*View.swift` | 下载、查询、历史及账户页面 / Download, explore, history and account screens |
| `DouyinLite/DownloadModel.swift` | 下载与保存状态 / Download and save state |
| `DouyinLite/BillingCenter.swift` | 报价、确认与余额刷新 / Quotes, approval and balance refresh |
| `DouyinLite/HistoryStore.swift` | 本机请求历史与费用推算 / Local request history and debit estimates |
| `DouyinLite/KeyStore.swift` | 钥匙串凭据存储 / Keychain credential storage |
| `DouyinLite/ConfigurationDocumentPicker.swift` | 系统配置文件导入 / System document import |
| `DouyinLite/Core/` | API、媒体下载、实况合成、配置读取 / API, media downloads, Live Photos and configuration parsing |
| `DouyinLite/Resources/` | Info.plist 与图标 / Info.plist and app assets |
| `DouyinLite.xcodeproj/` | 可再生工程和共享 scheme / Reproducible project and shared scheme |
| `scripts/` | 构建、工程生成、核心检查与图标生成 / Build, project generation, core checks and icon generation |
| `tests/` | 独立 Swift 检查程序 / Standalone Swift checks |
| `docs/` | 开发、API 及历史验证记录 / Development, API and historical verification notes |
| `build/`, `dist/` | 本地产物，Git 忽略 / Local outputs, ignored by Git |

## 构建 / Build

在仓库根目录执行 / Run from the repository root:

```sh
./scripts/build.sh
```

输出 `dist/DouyinLite-unsigned.ipa`，安装前需使用有效证书签名。构建不需要 API Key。脚本会在临时目录编译并自动清理，仅复制源码与 Xcode 工程，以兼容包含冒号的工作路径；同时使用单个编译任务。

This produces `dist/DouyinLite-unsigned.ipa`, which requires signing before installation. An API key is not required to build. The script stages only source and project files in a temporary directory, cleans it up on exit, and uses one build job. This also supports workspace paths containing a colon.

```sh
./scripts/build.sh --simulator
```

仅构建 `build/Simulator/DouyinLite.app`，不启动模拟器 / Builds the simulator app without launching a simulator.

如需在 Xcode 中修改工程，请优先调整生成脚本，再重新生成；构建脚本会覆盖工程文件。新增 `DouyinLite/` 下的 Swift 文件会自动纳入工程。

Edit the generator when changing project settings: every build regenerates the project. Swift files added under `DouyinLite/` are included automatically.

```sh
python3 scripts/generate_project.py
open DouyinLite.xcodeproj
```

使用 Xcode 真机运行时，在 Signing & Capabilities 中选择自己的团队并按需修改 Bundle Identifier；需要长期保留的设置应同步到生成脚本。

For device runs in Xcode, select your own signing team and adjust the bundle identifier as needed. Persist project setting changes in the generator.

## 配置 / Configuration

可直接在应用账户页粘贴 API Key。可选地复制 `.env.example` 为 `.env` 并填写密钥；设备构建时会在 `dist/` 生成独立的 `TikHub.env` 和 `TikHub.txt`，用于传到手机导入。它们包含私人密钥，不属于 IPA 或仓库内容。模拟器构建不生成这些配置副本。

Paste an API key in the app's account settings, or optionally copy `.env.example` to `.env` and fill it in. Device builds copy that file to `dist/TikHub.env` and `dist/TikHub.txt` for import on the phone. These private files are separate from the IPA and excluded from Git. Simulator builds do not export configuration copies.

## 验证 / Validation

```sh
./scripts/test.sh
```

默认仅执行 `tests/CoreTests.swift` 的离线检查，不读取真实密钥、不调用 API。它不是所有测试的统一入口，也不是 Xcode XCTest target。

By default this runs only the offline checks in `tests/CoreTests.swift`, without real credentials or API calls. It is not a runner for the entire test collection or an Xcode XCTest target.

| 文件 / File | 内容 / Scope |
| --- | --- |
| `CoreTests.swift` | 配置、分享链接、媒体响应解析 / Configuration, share links and response parsing |
| `QualityTests.swift` | 清晰度选择、去重与原画响应 / Quality selection, deduplication and original-quality responses |
| `BillingTests.swift` | 合成请求下的费用确认与余额逻辑 / Billing approval and balances with synthetic requests |
| `LivePhotoTests.swift` | 本地图片/视频配对、元数据与压缩样本保留 / Local Live Photo pairing, metadata and compressed sample preservation |

其他检查为独立程序，需要单独编译和运行；费用与实况检查的编译示例在对应文件顶部。历史检查范围与尚待真机验证的项目见 [验证记录](verification.md)，不代表当前提交重新运行过全部测试。

The remaining checks are standalone programs compiled and run separately; the billing and Live Photo files include compile examples. See [verification notes](verification.md) for historical coverage and device validation still outstanding; those results do not mean all checks were rerun for the current commit.

画质检查 / Quality checks:

```sh
mkdir -p build
xcrun swiftc -parse-as-library -module-cache-path build/ModuleCache.noindex \
  DouyinLite/Core/TikHub.swift tests/QualityTests.swift -o build/quality-tests
./build/quality-tests
```

若本地存在 `build/observed-response.json`，画质检查还会尝试校验该旧样例的特定字段；干净克隆不包含这个文件。If `build/observed-response.json` exists locally, quality checks also validate fields specific to that historical fixture. A fresh clone does not include it.

`test.sh --live` 和 `--inspect` 是旧版手动诊断模式，会读取 `.env` 并直接请求真实 API，可能计费，不经过应用的费用确认界面。`--fixture` 从本地 JSON 读取，但后续可能下载其中的远程媒体。日常离线检查不应传入这些参数。

The legacy `--live` and `--inspect` modes read `.env` and call the real API directly, potentially incurring charges without the app's approval dialog. `--fixture` reads local JSON but may subsequently download referenced remote media. Omit these options for routine offline checks.

## 修改约定 / Change guidelines

- API 请求经 `APITransport` 与 `BillingCenter`；保持报价后确认、单次发送与无自动收费重试。Route app API requests through these components and preserve quote/approval, single dispatch and no automatic paid retries.
- 媒体下载与 API 鉴权分开，下载链接不携带 API Key。Keep media requests separate from API authentication.
- 示例与测试使用虚构数据；不要提交配置、证书、实际响应或下载内容。Use synthetic examples and fixtures; exclude credentials, certificates, real responses and downloaded media.
- API 路径与参数变化时同步维护 [查询记录](explore-api.md) 和 [费用说明](billing-history-api.md)。Update the API notes when endpoint behavior changes.
