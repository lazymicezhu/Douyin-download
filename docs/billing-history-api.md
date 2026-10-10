# TikHub 调用历史与扣费来源核实

核实日期：2026-10-10（香港时间）。本次仅访问公开文档和免鉴权价格元数据；未读取用户密钥、未调用收费业务接口。

## 能确认的公开接口

基础地址均为 `https://api.tikhub.io`。

| 方法与路径 | 参数 / 鉴权 | 可确认的数据 | 公开元数据现价 |
| --- | --- | --- | --- |
| `GET /api/v1/tikhub/user/get_user_info` | 无查询参数；`Authorization: Bearer API_KEY` | 当前密钥所属账户的 `user_data.balance`、`user_data.free_credit`；二者是独立余额 | 0 USD；1 次/秒 |
| `GET /api/v1/tikhub/user/get_user_daily_usage` | 无查询参数；同上 | 当前账户的每日用量；实际响应字段已在开发期间只读核验，结构见下 | 0 USD；1 次/秒 |
| `GET /api/v1/tikhub/user/get_endpoint_info` | `endpoint=完整路径`；不需密钥 | `data.endpoint_uri`、`endpoint_cost`、`allow_free_credit`、`allow_discount`、`rate_limit` | 公开价格查询 |
| `GET /api/v1/tikhub/user/calculate_price` | `endpoint`、可选 `request_per_day`（默认 1）；Bearer | 对指定请求量的阶梯价格估算，不是已完成请求的实际扣费 | 本次未核实，不自动调用 |

余额响应结构是顶层字段（不是必须有 `data` 外层）：

```json
{
  "code": 200,
  "router": "/api/v1/tikhub/user/get_user_info",
  "api_key_data": { "api_key_name": "...", "api_key_scopes": [], "api_key_status": 1 },
  "user_data": { "email": "...", "balance": 1.23, "free_credit": 0.05 }
}
```

`get_user_daily_usage` 在公开 OpenAPI 中只有通用 `ResponseModel`，`data` 类型为任意值或 null。不能从该文档假造逐笔金额、扣费来源、日期范围或翻页参数。

### 每日汇总的实际结构补充

2026-10-10 开发验证先确认该接口免费，再用现有账户进行了只读调用；仅输出字段与类型，没有输出密钥或身份信息。观察到 `data` 包含：

```text
date: String
usage: Number
free_credit_usage: Number
balance_usage: Number
total_request_per_day: Integer
paid_request_per_day: Integer
last_requests_time: String
uri_counts: Dictionary<endpoint path, Integer>
```

这是实际响应观察，不是公开 schema 的字段保证。字段变化、缺失或非有限数时应显示不可用，不能默认为零。

公开官方后台脚本 [UsageLog-Bm8Iv8Bp.js](https://user.tikhub.io/assets/UsageLog-Bm8Iv8Bp.js) 的用量页面及 CSV 导出，把 `balance_usage` 和 `free_credit_usage` 用 `$` 前缀、四位小数格式化；官方定价明确使用 USD。这交叉支持将两个来源用量作为美元金额显示。公开 API 文档没有直接逐字段写明货币，不能声称它有该文字契约。后台脚本的每日总额叫 `total_usage`，当前 API 实测叫 `usage`；应验证实际 API 中 `usage ≈ balance_usage + free_credit_usage`，而不是把两个字段名无依据视为永久等价。

可新增“平台当日汇总”，直接显示服务端日期、总用量、正常余额用量、赠送额度用量和更新时间；这些是平台报告的账户级数字，不是本 App 独有消费，也不是本地逐笔历史累计。日期使用响应 `date`，不要自行改写为手机本地“今天”；通用响应默认时区为 `America/Los_Angeles`，但应保留实际响应信息，不能臆测所有统计永远用该时区。

逐笔推算可以优先比较每日汇总：要求前后 `date` 相同、`paid_request_per_day` 恰好增加 1、目标 `uri_counts[path]` 恰好增加 1、其他收费路径无新增（未确认是否免费的新增路径应视作冲突）；用 `balance_usage` 与 `free_credit_usage` 的增量分开记录。还要验证所有计数不回退、来源增量非负、总金额关系一致、增量不超过已确认报价。已知免费的账户查询可能增加总请求数，因此不能简单要求 `total_request_per_day` 只增加 1。

这种关联比余额差更不受充值干扰，但仍不是按 `request_id` 返回的账单，延迟结算或其他客户端并发存在时不能保证一对一归属。必须标记“按平台日用量变化推算”；不满足上述条件则保留“待核实”。

公开 OpenAPI 的 TikHub 用户目录只有上述四项及 `get_tiered_discount_info`、`get_all_endpoints_info`。检查整个路径表没有发现按 `request_id` 查消费明细或实际账单的公开接口。**这是“当前公开接口未找到”，不是断言平台内部没有。**

通用业务响应包含 `request_id`、`router`、时间、`params`、`data`，不含公开定义的实际扣费金额或资金来源字段。`message_zh` 中“本次请求将被计费”是模型默认文本，连本次实测的免费价格查询也出现，不能据此判定实际扣费。

## 历史功能的可信实现边界

1. 为每次真正发出的业务请求先写入本地记录：时间、功能、路径、报价、状态；拿到响应后补 `request_id`。不保存密钥、请求头或整份响应。
2. 收费前后各取一次免费余额快照，按 `前值 − 后值` 分别记录赠送余额和正常余额的减少量。零差额只能叫“暂未观察到扣费”，不能承诺永不收费。
3. 两次快照是整个账户的变化，不是平台逐笔账单。UI 必须标记“按余额变化推算”；即使金额恰好等于报价，也不能改称“已核实账单”。其他设备、其他密钥、充值、赠款、异步结算都会干扰归属。
4. 缺少前/后快照、金额增加、超过报价、遇到延迟、网络超时或取消后服务端状态不明，显示“待核实”，保留报价且不把它填成实际费用。零变化不能计入确定花费。
5. `allow_free_credit=true` 只表示该端点允许使用赠送额度，不能据此声称这次一定扣赠送额度。`false` 说明不能使用赠送额度，但实际是否完成扣款仍要观察或核实。
6. 账户余额接口本身按每次公开报价核实仍免费；未来如改价、无法确认价格，不自动产生费用。历史界面不能为了刷新记录偷偷再次调用付费业务接口。
7. 正在执行的本地收费请求应串行，历史按密钥不可逆摘要隔离；更换密钥后旧请求的结果不能记到新账户。若要同账户不同密钥合并，需进一步核实稳定账户标识，不能用用户名猜测。
8. 本地逐笔历史从安装此版后的调用开始；平台当日汇总可以包括此前及其他客户端使用。公开接口目前不足以可靠追溯此前每笔扣费的来源。

## 证据

- [用户信息](https://docs.tikhub.io/186826050e0)：当前账户、独立 `balance` / `free_credit` 字段。
- [每日用量](https://docs.tikhub.io/186826051e0)：当前账户每日用量，无具体消费明细结构。
- [计算价格](https://docs.tikhub.io/186826052e0)：按输入请求量计算阶梯费用。
- [端点信息](https://docs.tikhub.io/186826054e0)：路径价格及可用额度类型。
- [官方 OpenAPI](https://api.tikhub.io/openapi.json)：目录与 schema；本地已缓存为 `build/openapi.json`。
- [官方价格说明](https://tikhub.io/pricing)：正常余额与赠送额度分开；部分接口只扣正常余额；同参数重复请求仍会各自计费。

本次价格元数据实测：`get_user_info` 与 `get_user_daily_usage` 都返回 `endpoint_cost: 0.0`、`allow_discount: false`、`rate_limit: "1/second"`。这些是 2026-10-10 查询时的现价，不是永久免费保证。
