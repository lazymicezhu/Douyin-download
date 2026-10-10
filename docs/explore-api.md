# 查询功能接口核对记录

核对时间：2026-10-10T05:58:51.936879+00:00（UTC）。官方 OpenAPI 版本：V5.3.2。

来源为 [TikHub 官方 OpenAPI](https://api.tikhub.io/openapi.json) 和 [官方接口定价元数据](https://api.tikhub.io/api/v1/tikhub/user/get_endpoint_info)。后者通过 `endpoint` 查询参数逐个核对以下 20 个路径；全部返回相同的 `endpoint_uri`，无路径规范化差异。未发送密钥、未读取 `.env`、未发起任何收费业务请求。接口存在及字段规则已核实；具体账号和作品的实时可用性未付费实测。

下表价格是核对时的美元基础单价。应用每次实际查询和翻页前重新获取报价，并由用户确认。折扣、赠送额度及未来调价以当次元数据为准；内容趋势指南的说明文字曾写 $0.002，当前定价元数据为 $0.001，因此不能把说明文字硬编码为收费价格。

| 功能 | 方法与官方说明 | 基础价/次 | 赠送额度 | 折扣 |
| --- | --- | --- | --- | --- |
| 作者资料 | [GET `/api/v1/douyin/web/handler_user_profile_v2`](https://api.tikhub.io/#/Douyin-Web-API/handler_user_profile_v2_api_v1_douyin_web_handler_user_profile_v2_get) | $0.001 | 支持 | 支持 |
| 从主页链接找作者 | [GET `/api/v1/douyin/web/get_sec_user_id`](https://api.tikhub.io/#/Douyin-Web-API/get_sec_user_id_api_v1_douyin_web_get_sec_user_id_get) | $0.001 | 支持 | 支持 |
| 主页作品 | [GET `/api/v1/douyin/app/v3/fetch_user_post_videos`](https://api.tikhub.io/#/Douyin-App-V3-API/fetch_user_post_videos_api_v1_douyin_app_v3_fetch_user_post_videos_get) | $0.001 | 不支持 | 不支持 |
| 作品评论 | [GET `/api/v1/douyin/web/fetch_video_comments`](https://api.tikhub.io/#/Douyin-Web-API/fetch_video_comments_api_v1_douyin_web_fetch_video_comments_get) | $0.001 | 支持 | 支持 |
| 评论回复 | [GET `/api/v1/douyin/web/fetch_video_comment_replies`](https://api.tikhub.io/#/Douyin-Web-API/fetch_video_comments_reply_api_v1_douyin_web_fetch_video_comment_replies_get) | $0.001 | 支持 | 支持 |
| 搜索作品 | [POST `/api/v1/douyin/search/fetch_video_search_v5`](https://api.tikhub.io/#/Douyin-Search-API/fetch_video_search_v5_api_v1_douyin_search_fetch_video_search_v5_post) | $0.01 | 不支持 | 不支持 |
| 抖音热榜 | [GET `/api/v1/douyin/app/v3/fetch_hot_search_list`](https://api.tikhub.io/#/Douyin-App-V3-API/fetch_hot_search_list_api_v1_douyin_app_v3_fetch_hot_search_list_get) | $0.001 | 支持 | 不支持 |
| 音乐信息 | [GET `/api/v1/douyin/app/v3/fetch_music_detail`](https://api.tikhub.io/#/Douyin-App-V3-API/fetch_music_detail_api_v1_douyin_app_v3_fetch_music_detail_get) | $0.001 | 支持 | 支持 |
| 合集详情 | [GET `/api/v1/douyin/app/v3/fetch_video_mix_detail`](https://api.tikhub.io/#/Douyin-App-V3-API/fetch_video_mix_detail_api_v1_douyin_app_v3_fetch_video_mix_detail_get) | $0.001 | 支持 | 支持 |
| 合集作品 | [GET `/api/v1/douyin/app/v3/fetch_video_mix_post_list`](https://api.tikhub.io/#/Douyin-App-V3-API/fetch_video_mix_post_list_api_v1_douyin_app_v3_fetch_video_mix_post_list_get) | $0.001 | 支持 | 支持 |
| 直播信息 | [GET `/api/v1/douyin/web/fetch_user_live_videos`](https://api.tikhub.io/#/Douyin-Web-API/fetch_user_live_videos_api_v1_douyin_web_fetch_user_live_videos_get) | $0.001 | 支持 | 支持 |
| 查找星图达人 ID | [GET `/api/v1/douyin/xingtu_v2/get_xingtu_kolid_by_unique_id`](https://api.tikhub.io/#/Douyin-Xingtu-V2-API/get_xingtu_kolid_by_unique_id_api_v1_douyin_xingtu_v2_get_xingtu_kolid_by_unique_id_get) | $0.002 | 不支持 | 不支持 |
| 星图达人搜索 | [GET `/api/v1/douyin/xingtu_v2/search_creator`](https://api.tikhub.io/#/Douyin-Xingtu-V2-API/search_creator_api_v1_douyin_xingtu_v2_search_creator_get) | $0.002 | 不支持 | 不支持 |
| 星图达人资料 | [GET `/api/v1/douyin/xingtu_v2/get_author_base_info`](https://api.tikhub.io/#/Douyin-Xingtu-V2-API/get_author_base_info_api_v1_douyin_xingtu_v2_get_author_base_info_get) | $0.002 | 不支持 | 不支持 |
| 星图粉丝画像 | [GET `/api/v1/douyin/xingtu_v2/get_author_fans_distribution`](https://api.tikhub.io/#/Douyin-Xingtu-V2-API/get_author_fans_distribution_api_v1_douyin_xingtu_v2_get_author_fans_distribution_get) | $0.002 | 不支持 | 不支持 |
| 星图受众画像 | [GET `/api/v1/douyin/xingtu_v2/get_author_audience_distribution`](https://api.tikhub.io/#/Douyin-Xingtu-V2-API/get_author_audience_distribution_api_v1_douyin_xingtu_v2_get_author_audience_distribution_get) | $0.002 | 不支持 | 不支持 |
| 趋势关键词 | [GET `/api/v1/douyin/index/fetch_hot_trend_word`](https://api.tikhub.io/#/Douyin-Index-API/fetch_hot_trend_word_api_v1_douyin_index_fetch_hot_trend_word_get) | $0.001 | 不支持 | 不支持 |
| 关键词可查日期 | [POST `/api/v1/douyin/index/fetch_keyword_valid_date`](https://api.tikhub.io/#/Douyin-Index-API/fetch_keyword_valid_date_api_v1_douyin_index_fetch_keyword_valid_date_post) | $0.001 | 支持 | 支持 |
| 关键词热度趋势 | [POST `/api/v1/douyin/index/fetch_multi_keyword_hot_trend`](https://api.tikhub.io/#/Douyin-Index-API/fetch_multi_keyword_hot_trend_api_v1_douyin_index_fetch_multi_keyword_hot_trend_post) | $0.003 | 不支持 | 不支持 |
| 内容趋势指南 | [GET `/api/v1/douyin/xingtu_v2/get_content_trend_guide`](https://api.tikhub.io/#/Douyin-Xingtu-V2-API/get_content_trend_guide_api_v1_douyin_xingtu_v2_get_content_trend_guide_get) | $0.001 | 支持 | 不支持 |

## 参数与分页

除搜索作品的 JSON 请求体外，全部字段放 URL 查询参数，包括两个 POST 趋势接口。所有请求仅发送至 `https://api.tikhub.io`，凭据由上层网络服务放在 Authorization 请求头。空的可选参数不发送，整数保持其对应请求位置要求的类型。

### 作者资料

URL 查询参数：`unique_id`（必填）。

### 从主页链接找作者

URL 查询参数：`url`（必填）。

### 主页作品

URL 查询参数：`sec_user_id`（必填）；`sort_type`（可选，默认 `0`）；`max_cursor`（可选，默认 `0`）；`count`（可选，默认 `20`）；`channel`（可选，默认 `normal`）。

### 作品评论

URL 查询参数：`aweme_id`（必填）；`cursor`（可选，默认 `0`）；`count`（可选，默认 `20`）。

### 评论回复

URL 查询参数：`item_id`（必填）；`comment_id`（必填）；`cursor`（可选，默认 `0`）；`count`（可选，默认 `20`）。

### 搜索作品

JSON 请求体：`keyword`（必填）；`offset`（可选，默认 `0`）；`page`（可选，默认 `1`）；`search_id`（可选，默认留空）；`backtrace`（可选，默认留空）。

### 抖音热榜

URL 查询参数：`board_type`（可选，默认 `0`）；`board_sub_type`（可选，默认留空）。

### 音乐信息

URL 查询参数：`music_id`（必填）。

### 合集详情

URL 查询参数：`mix_id`（必填）。

### 合集作品

URL 查询参数：`mix_id`（必填）；`cursor`（可选，默认 `0`）；`count=20`（固定；官方提示修改数量可能导致错误）。

### 直播信息

URL 查询参数：`webcast_id`（必填）。

### 查找星图达人 ID

URL 查询参数：`unique_id`（必填）。

### 星图达人搜索

URL 查询参数：`keyword`（可选，默认留空）；`seach_type`（可选，默认 `2`）；`time_range_days`（可选，默认 `180`）；`page`（可选，默认 `1`）；`fans_min`（可选，默认留空）；`fans_max`（可选，默认留空）。

### 星图达人资料

URL 查询参数：`o_author_id`（必填）。

### 星图粉丝画像

URL 查询参数：`o_author_id`（必填）。

### 星图受众画像

URL 查询参数：`o_author_id`（必填）；`link_type`（必填，默认 `5`）。

### 趋势关键词

URL 查询参数：`type`（可选，默认 `0`）；`app_name=aweme`（固定抖音平台）。

### 关键词可查日期

URL 查询参数：`keyword_list`（必填）。

### 关键词热度趋势

URL 查询参数：`keyword_list`（必填）；`start_date`（必填）；`end_date`（必填）；`region`（可选，默认留空）；`app_name=aweme`（固定抖音平台）。

### 内容趋势指南

URL 查询参数：无需参数。

## 必须保留的约定

- 主页作品：`max_cursor=0` 起步，后续原样续传响应的 `max_cursor`；`sort_type` 为 0 最新 / 1 最热；`channel` 为 `normal` 或 `lite`。
- 评论使用 `aweme_id`，评论回复使用 **`item_id` + `comment_id`**，不可混用。回复、评论和合集作品均续传 `cursor`；`has_more=false/0` 停止翻页。
- 作品搜索 V5 固定每页 10 条，`page` 范围 1 至 200。下一页必须同时原样回传 `data.pagination.offset`、`search_id`、`backtrace`，再令 `page + 1`；不能只加页码。
- 星图搜索的参数拼写是官方的 **`seach_type`**。2 为昵称、3 为内容；内容范围 30 / 90 / 180 天。`page` 从 1 开始；每页数量由接口固定。
- 星图画像/资料需要星图 `o_author_id`，不能把抖音 `uid`、`sec_uid` 直接代入。受众画像还必须有 `link_type`；默认 5 来自官方示例，不承诺其他数值含义。
- 直播信息需要直播链接里的 `webcast_id`，例如 `douyin.com/root/live/376034101029` 的最后一段；它不是结果里的 `room_id`。
- 热榜：热点为 `board_type=0` 且子类型空；其他为 `board_type=2`，子类型 `seeding` / `2` / `4` / `hotspot_challenge` 对应种草 / 娱乐 / 社会 / 挑战。
- 趋势推荐词按天更新，并非实时热榜。每日热度查询先查可用日期，日期格式 YYYYMMDD，多个词或地区用逗号分隔；可用日期查询本身也是一次独立业务请求。
- 星图其余可选参数未覆盖的部分沿用服务默认值，未宣称实现全部筛选器。

## 解码与验证

`ExploreDecoder` 展示常用中文字段、作品/评论/达人列表、嵌套画像分布与趋势序列，同时保留完整 JSON 供展开和导出。大整数 ID 以字符串呈现，不先转换为浮点数。卡片最多 20 节、每节 100 行，单值最多 2000 字符，深层内容仍保留在 JSON 中；隐藏调试字段不会自动发起任何查询。结果中的图片地址仅提供给上层显示，不会转成 API 请求。

本地验证涵盖：20 个路径/方法/必填字段与 OpenAPI 一一对应；20 个公开元数据路径精确匹配；Swift 类型检查；POST 请求体与 POST 查询参数区分；搜索分页信息续传；最后一页停止；无效链接/日期/数量拒绝；嵌套画像解码；大整数精度；完整 JSON 导出。全部使用本地构造的响应，无付费端到端请求。

公开缓存：`build/openapi.json`、`build/explore-endpoint-quotes.json`；build 为忽略目录，不应作为运行时依赖。
