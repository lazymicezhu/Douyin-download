import Foundation
import CoreFoundation

enum ExploreInputKind: String, Equatable { case text, integer }

struct ExploreField: Identifiable, Equatable {
    let key: String
    let label: String
    let placeholder: String
    let defaultValue: String
    let required: Bool
    let inputKind: ExploreInputKind
    let help: String
    var id: String { key }

    init(_ key: String, _ label: String, placeholder: String = "", defaultValue: String = "",
         required: Bool = false, inputKind: ExploreInputKind = .text, help: String = "") {
        self.key = key; self.label = label; self.placeholder = placeholder
        self.defaultValue = defaultValue; self.required = required
        self.inputKind = inputKind; self.help = help
    }
}

struct ExploreEndpoint: Identifiable, Equatable {
    let id: String
    let title: String
    let category: String
    let summary: String
    let path: String
    let method: String
    let fields: [ExploreField]
    let docsURL: URL?
    fileprivate let bodyKeys: Set<String>
    fileprivate let fixedQuery: [String: String]
    fileprivate let cursorKey: String?

    fileprivate init(_ id: String, _ title: String, category: String, summary: String,
                     path: String, method: String = "GET", fields: [ExploreField] = [],
                     bodyKeys: Set<String> = [], fixedQuery: [String: String] = [:], cursorKey: String? = nil) {
        self.id = id; self.title = title; self.category = category; self.summary = summary
        self.path = path; self.method = method; self.fields = fields
        self.bodyKeys = bodyKeys; self.fixedQuery = fixedQuery; self.cursorKey = cursorKey
        self.docsURL = URL(string: "https://api.tikhub.io/")
    }
}

enum ExploreCatalog {
    private static func id(_ key: String, _ label: String, _ help: String) -> ExploreField {
        ExploreField(key, label, required: true, help: help)
    }
    private static func integer(_ key: String, _ label: String, _ value: String, _ help: String = "") -> ExploreField {
        ExploreField(key, label, defaultValue: value, inputKind: .integer, help: help)
    }
    private static let cursor = integer("cursor", "翻页位置", "0", "首次保持 0；后续使用结果中的下一页位置。")
    private static let count = integer("count", "每页数量", "20", "建议保持 20，最多 20 条。")
    private static let authorID = id("o_author_id", "星图达人 ID", "先用“查找星图达人 ID”或“星图达人搜索”，复制结果中的达人 ID。")
    private static let videoIDHelp = "从作品查询结果复制作品 ID，或输入抖音网页版视频链接中的数字。"

    // Verified against the public OpenAPI snapshot in build/openapi.json.
    // Some POST endpoints deliberately have query parameters, not a JSON body.
    static let endpoints: [ExploreEndpoint] = [
        .init("author", "作者资料", category: "作者与作品", summary: "通过抖音号查询昵称、简介、粉丝和作品统计。",
              path: "/api/v1/douyin/web/handler_user_profile_v2", fields: [
                id("unique_id", "抖音号", "在作者主页昵称下方找到抖音号；填写账号，不是昵称。")]),
        .init("author-link", "从主页链接找作者", category: "作者与作品", summary: "把作者分享链接转换为查询主页作品所需的用户标识。",
              path: "/api/v1/douyin/web/get_sec_user_id", fields: [
                id("url", "作者主页链接", "在抖音作者主页分享并复制链接。")]),
        .init("posts", "主页作品", category: "作者与作品", summary: "查询作者发布的作品，支持最新或最热排序。",
              path: "/api/v1/douyin/app/v3/fetch_user_post_videos", fields: [
                id("sec_user_id", "用户标识", "从“作者资料”或“从主页链接找作者”的结果复制用户标识，通常以 MS4w 开头。"),
                integer("sort_type", "排序", "0", "0 为最新，1 为最热。"),
                integer("max_cursor", "翻页位置", "0", "首次保持 0。"), count,
                .init("channel", "抖音版本", defaultValue: "normal", help: "normal 为正常版；最新作品缺失时可尝试 lite。")], cursorKey: "max_cursor"),
        .init("comments", "作品评论", category: "评论", summary: "查询某个作品下的评论、点赞数和评论 ID。",
              path: "/api/v1/douyin/web/fetch_video_comments", fields: [id("aweme_id", "作品 ID", videoIDHelp), cursor, count], cursorKey: "cursor"),
        .init("replies", "评论回复", category: "评论", summary: "查询某条评论的回复。",
              path: "/api/v1/douyin/web/fetch_video_comment_replies", fields: [
                id("item_id", "作品 ID", videoIDHelp), id("comment_id", "评论 ID", "先查询作品评论，再复制对应评论的评论 ID。"), cursor, count], cursorKey: "cursor"),
        .init("search", "搜索作品", category: "搜索与热榜", summary: "按关键词搜索视频，每页 10 条；支持继续查询下一页。",
              path: "/api/v1/douyin/search/fetch_video_search_v5", method: "POST", fields: [
                .init("keyword", "关键词", placeholder: "例如：旅行、美食", required: true),
                integer("offset", "翻页位置", "0"), integer("page", "页码", "1", "1 至 200。"),
                .init("search_id", "搜索标识", help: "首次留空；查询下一页时自动沿用。"),
                .init("backtrace", "翻页标识", help: "首次留空；查询下一页时自动沿用。")],
              bodyKeys: ["keyword", "offset", "page", "search_id", "backtrace"], cursorKey: "offset"),
        .init("hot", "抖音热榜", category: "搜索与热榜", summary: "查看热点、种草、娱乐、社会和挑战榜。",
              path: "/api/v1/douyin/app/v3/fetch_hot_search_list", fields: [
                .init("board_type", "榜单类型", defaultValue: "0", help: "0 为热点榜；其他榜单填 2。"),
                .init("board_sub_type", "榜单分类", help: "热点留空；种草填 seeding，娱乐填 2，社会填 4，挑战填 hotspot_challenge。")]),
        .init("music", "音乐信息", category: "音乐与合集", summary: "查看音乐名称、作者和相关信息。",
              path: "/api/v1/douyin/app/v3/fetch_music_detail", fields: [id("music_id", "音乐 ID", "从作品结果的音乐信息复制音乐 ID，或从音乐分享链接中查找。")]),
        .init("mix", "合集详情", category: "音乐与合集", summary: "查询合集名称、作者和作品统计。",
              path: "/api/v1/douyin/app/v3/fetch_video_mix_detail", fields: [id("mix_id", "合集 ID", "从作品结果的合集信息或合集分享链接中复制合集 ID。")]),
        .init("mix-posts", "合集作品", category: "音乐与合集", summary: "按顺序查看合集内的作品，每页固定请求 20 条。",
              path: "/api/v1/douyin/app/v3/fetch_video_mix_post_list", fields: [id("mix_id", "合集 ID", "从“合集详情”结果或合集分享链接复制合集 ID。"), cursor],
              fixedQuery: ["count": "20"], cursorKey: "cursor"),
        .init("live", "直播信息", category: "直播", summary: "查看直播间信息与开播情况。",
              path: "/api/v1/douyin/web/fetch_user_live_videos", fields: [
                id("webcast_id", "直播间号码", "填写直播链接最后一段数字，例如 douyin.com/root/live/376034101029 中的 376034101029；这与房间 ID 不同。")]),
        .init("xingtu-id", "查找星图达人 ID", category: "星图", summary: "通过抖音号找到对应的星图达人；未入驻时会返回不存在。",
              path: "/api/v1/douyin/xingtu_v2/get_xingtu_kolid_by_unique_id", fields: [id("unique_id", "抖音号", "在作者主页昵称下方找到抖音号。")]),
        .init("xingtu-search", "星图达人搜索", category: "星图", summary: "按昵称或内容找达人，并按粉丝数量筛选。",
              path: "/api/v1/douyin/xingtu_v2/search_creator", fields: [
                .init("keyword", "关键词", placeholder: "达人昵称或内容关键词", help: "留空可按筛选条件浏览达人。"),
                integer("seach_type", "搜索方式", "2", "2 按昵称，3 按内容。"),
                integer("time_range_days", "内容时间范围", "180", "按内容搜索时生效：30、90 或 180 天。"),
                integer("page", "页码", "1"),
                .init("fans_min", "最少粉丝", inputKind: .integer, help: "可留空。"),
                .init("fans_max", "最多粉丝", inputKind: .integer, help: "可留空。")]),
        .init("xingtu-profile", "星图达人资料", category: "星图", summary: "查看星图创作者的基本资料。",
              path: "/api/v1/douyin/xingtu_v2/get_author_base_info", fields: [authorID]),
        .init("xingtu-fans", "星图粉丝画像", category: "星图", summary: "查询粉丝性别、年龄、地域和兴趣等分布。",
              path: "/api/v1/douyin/xingtu_v2/get_author_fans_distribution", fields: [authorID]),
        .init("xingtu-audience", "星图受众画像", category: "星图", summary: "查询创作者的受众分布，与粉丝画像分别展示。",
              path: "/api/v1/douyin/xingtu_v2/get_author_audience_distribution", fields: [authorID,
                .init("link_type", "画像类型", defaultValue: "5", required: true, inputKind: .integer, help: "官方示例为 5；查询其他类型时填写相应类型编号。")]),
        .init("trend-words", "趋势关键词", category: "趋势分析", summary: "查看按天更新的指数推荐关键词，帮助选择分析主题。",
              path: "/api/v1/douyin/index/fetch_hot_trend_word", fields: [integer("type", "推荐类型", "0", "0 为搜索热词，1 为内容热词。")], fixedQuery: ["app_name": "aweme"]),
        .init("trend-dates", "关键词可查日期", category: "趋势分析", summary: "先查看关键词有数据的日期范围，再查询趋势。",
              path: "/api/v1/douyin/index/fetch_keyword_valid_date", method: "POST", fields: [
                .init("keyword_list", "关键词", placeholder: "美食,旅游", required: true, help: "多个词用逗号分隔。")]),
        .init("trend", "关键词热度趋势", category: "趋势分析", summary: "比较一个或多个关键词在指定日期内的每日热度。",
              path: "/api/v1/douyin/index/fetch_multi_keyword_hot_trend", method: "POST", fields: [
                .init("keyword_list", "关键词", placeholder: "美食,旅游", required: true, help: "多个词用逗号分隔。"),
                .init("start_date", "开始日期", placeholder: "YYYYMMDD", required: true, help: "例如 20260901；先查询可用日期范围。"),
                .init("end_date", "结束日期", placeholder: "YYYYMMDD", required: true),
                .init("region", "地区", placeholder: "例如：上海,北京", help: "留空表示全国，多个地区用逗号分隔。")], fixedQuery: ["app_name": "aweme"]),
        .init("content-trends", "内容趋势指南", category: "趋势分析", summary: "查看星图提供的内容趋势指南。",
              path: "/api/v1/douyin/xingtu_v2/get_content_trend_guide")
    ]

    static var categories: [String] {
        endpoints.reduce(into: []) { if !$0.contains($1.category) { $0.append($1.category) } }
    }

    static func request(for endpoint: ExploreEndpoint, values: [String: String]) throws -> APIRequest {
        var query = endpoint.fixedQuery
        var body: [String: Any] = [:]
        for field in endpoint.fields {
            var value = (values[field.key] ?? field.defaultValue).trimmingCharacters(in: .whitespacesAndNewlines)
            if value.isEmpty && field.inputKind == .integer && !field.defaultValue.isEmpty { value = field.defaultValue }
            if ["keyword_list", "region"].contains(field.key) { value = value.replacingOccurrences(of: "，", with: ",") }
            if field.required && value.isEmpty { throw AppError.message("请填写\(field.label)。") }
            if value.isEmpty {
                if endpoint.bodyKeys.contains(field.key) { body[field.key] = "" }
                continue
            }
            guard value.utf8.count <= 4096 else { throw AppError.message("\(field.label)过长，请缩短后重试。") }
            if field.key == "url" { value = try validatedDouyinURL(value).absoluteString }
            let typedValue: Any
            if field.inputKind == .integer {
                guard let number = Int(value), number >= 0 else { throw AppError.message("\(field.label)应为非负整数。") }
                if field.key == "count" && !(1...20).contains(number) { throw AppError.message("每页数量应在 1 至 20 之间。") }
                if field.key == "page" && (number < 1 || (endpoint.id == "search" && number > 200)) { throw AppError.message("请填写有效页码；作品搜索最多 200 页。") }
                if field.key == "sort_type" && endpoint.id == "posts" && ![0, 1].contains(number) { throw AppError.message("作品排序请填 0 或 1。") }
                if field.key == "seach_type" && ![2, 3].contains(number) { throw AppError.message("搜索方式请填 2 或 3。") }
                if field.key == "time_range_days" && ![30, 90, 180].contains(number) { throw AppError.message("内容时间范围请填 30、90 或 180。") }
                if endpoint.id == "trend-words" && field.key == "type" && ![0, 1].contains(number) { throw AppError.message("推荐类型请填 0 或 1。") }
                typedValue = number
            } else { typedValue = value }
            if ["start_date", "end_date"].contains(field.key) && !validDate(value) { throw AppError.message("\(field.label)格式应为有效日期 YYYYMMDD。") }
            if field.key == "channel" && !["normal", "lite"].contains(value) { throw AppError.message("抖音版本请填 normal 或 lite。") }
            if endpoint.bodyKeys.contains(field.key) { body[field.key] = typedValue } else { query[field.key] = value }
        }
        if let start = query["start_date"], let end = query["end_date"], start > end { throw AppError.message("开始日期不能晚于结束日期。") }
        if let minimum = query["fans_min"].flatMap(Int.init), let maximum = query["fans_max"].flatMap(Int.init), minimum > maximum { throw AppError.message("最少粉丝不能大于最多粉丝。") }
        if endpoint.id == "hot" {
            let type = query["board_type"] ?? "0", subtype = query["board_sub_type"] ?? ""
            guard (type == "0" && subtype.isEmpty) || (type == "2" && ["seeding", "2", "4", "hotspot_challenge"].contains(subtype)) else {
                throw AppError.message("热点榜请填类型 0 并留空分类；其他榜单请填类型 2 并选择有效分类。")
            }
        }
        return APIRequest(title: endpoint.title, path: endpoint.path, method: endpoint.method,
                          query: query, body: endpoint.bodyKeys.isEmpty ? nil : body)
    }

    static func nextValues(for endpoint: ExploreEndpoint, result: ExploreResult, currentValues: [String: String]) -> [String: String]? {
        guard result.hasMore != false else { return nil }
        var next = currentValues
        if let key = endpoint.cursorKey {
            guard let cursor = result.nextPageValues[key], !cursor.isEmpty,
                  cursor != (currentValues[key] ?? endpoint.fields.first(where: { $0.key == key })?.defaultValue) else { return nil }
            next[key] = cursor
            if endpoint.id == "search" {
                guard let searchID = result.nextPageValues["search_id"], let backtrace = result.nextPageValues["backtrace"] else { return nil }
                next["search_id"] = searchID; next["backtrace"] = backtrace
                let page = Int(currentValues["page"] ?? "1") ?? 1
                guard page < 200 else { return nil }
                next["page"] = String(page + 1)
            }
            return next
        }
        if endpoint.id == "xingtu-search", result.sections.contains(where: { !$0.rows.isEmpty }) {
            next["page"] = String((Int(currentValues["page"] ?? "1") ?? 1) + 1)
            return next
        }
        return nil
    }

    private static func validDate(_ text: String) -> Bool {
        guard text.count == 8, text.allSatisfy(\.isNumber) else { return false }
        let format = DateFormatter(); format.locale = Locale(identifier: "en_US_POSIX")
        format.timeZone = TimeZone(secondsFromGMT: 0); format.dateFormat = "yyyyMMdd"; format.isLenient = false
        return format.date(from: text).map { format.string(from: $0) == text } ?? false
    }

    private static func validatedDouyinURL(_ text: String) throws -> URL {
        let detector = try NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        for match in detector.matches(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text)) {
            guard let url = match.url, let host = url.host?.lowercased(),
                  ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.user == nil, url.password == nil,
                  ["douyin.com", "iesdouyin.com"].contains(where: { host == $0 || host.hasSuffix("." + $0) }),
                  url.port == nil || [80, 443].contains(url.port!),
                  var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { continue }
            components.scheme = "https"; components.port = nil; components.fragment = nil
            if let result = components.url { return result }
        }
        throw AppError.message("没有找到有效的抖音作者主页链接。")
    }
}

struct ExploreValue: Identifiable, Equatable {
    let label: String
    let value: String
    var id: String { label + ":" + value }
}
struct ExploreRow: Identifiable, Equatable {
    let id: String
    let title: String
    let subtitle: String
    let values: [ExploreValue]
    let imageURL: URL?
}
struct ExploreSection: Identifiable, Equatable {
    let id: String
    let title: String
    let rows: [ExploreRow]
}
struct ExploreResult: Equatable {
    let title: String
    let summary: [ExploreValue]
    let sections: [ExploreSection]
    let rawJSON: Data
    let nextCursor: String?
    let hasMore: Bool?
    let nextPageValues: [String: String]
}

enum ExploreDecoder {
    private static let hidden: Set<String> = ["status_code", "statusCode", "code", "log_pb", "extra", "logid", "request_id", "authentication_token", "token", "cookie", "cookies", "access_token", "refresh_token", "aweme_acl", "client_key", "backtrace", "search_id", "pagination", "config"]
    private static let labels: [String: String] = [
        "data": "查询结果", "items": "作品", "aweme_list": "作品", "aweme_details": "作品", "aweme_detail": "作品信息",
        "comments": "评论", "replies": "回复", "user": "作者", "users": "作者列表", "user_info": "作者资料", "author": "作者",
        "nickname": "昵称", "nick_name": "昵称", "name": "名称", "title": "标题", "desc": "描述", "text": "内容", "signature": "简介",
        "aweme_id": "作品 ID", "item_id": "作品 ID", "cid": "评论 ID", "comment_id": "评论 ID", "reply_id": "回复 ID",
        "uid": "用户 ID", "sec_uid": "用户标识", "sec_user_id": "用户标识", "unique_id": "抖音号", "short_id": "短号",
        "author_id": "达人 ID", "o_author_id": "星图达人 ID", "id": "ID", "kol_id": "星图达人 ID", "exist": "是否存在",
        "follower_count": "粉丝数", "fans_count": "粉丝数", "following_count": "关注数", "aweme_count": "作品数", "total_favorited": "总获赞",
        "digg_count": "点赞数", "comment_count": "评论数", "share_count": "分享数", "collect_count": "收藏数", "play_count": "播放量",
        "reply_comment_total": "回复数", "statistics": "统计", "stats": "统计", "create_time": "发布时间", "update_time": "更新时间",
        "music": "音乐", "music_info": "音乐信息", "music_id": "音乐 ID", "id_str": "ID", "music_name": "音乐名称",
        "mix_info": "合集信息", "mix_name": "合集名称", "mix_id": "合集 ID", "total": "总数", "count": "数量",
        "room": "直播间", "rooms": "直播间", "room_id": "房间 ID", "web_rid": "直播间号码", "webcast_id": "直播间号码",
        "status": "状态", "user_count": "观看人数", "user_count_str": "观看人数", "owner": "主播", "online_count": "在线人数",
        "word": "关键词", "word_list": "热榜", "trend_words": "推荐词", "hot_value": "热度", "sentence_id": "话题 ID", "position": "排名",
        "keyword": "关键词", "keyword_list": "关键词", "start_date": "开始日期", "end_date": "结束日期", "date": "日期", "dates": "日期",
        "distributions": "画像分布", "distribution": "分布", "gender": "性别", "age": "年龄", "province": "省份", "city": "城市",
        "distribution_list": "分布明细", "distribution_type": "画像类型", "distribution_name": "画像维度",
        "values": "数值", "series": "趋势序列", "trend": "趋势", "hot_trend": "热度趋势", "x": "横轴", "y": "数值",
        "ratio": "占比", "percent": "百分比", "percentage": "百分比", "value": "数值", "label": "分类", "fans": "粉丝",
        "authors": "达人", "author_list": "达人列表", "author_info": "达人资料", "base_info": "基本资料", "list": "列表",
        "max_cursor": "下一页位置", "cursor": "下一页位置", "offset": "下一页位置", "has_more": "还有下一页", "page": "页码",
        "duration": "时长（原始值）", "width": "宽度", "height": "高度", "score": "评分", "message": "提示", "message_zh": "提示", "msg": "提示"
    ]
    private static let preferredKeys = ["nickname", "nick_name", "title", "mix_name", "music_name", "word", "name", "text", "desc", "label", "keyword", "date"]
    private static let orderedKeys = ["nickname", "signature", "unique_id", "sec_uid", "sec_user_id", "uid", "o_author_id", "author_id", "aweme_id", "cid", "comment_id", "music_id", "mix_id", "desc", "text", "title", "word", "follower_count", "fans_count", "aweme_count", "total_favorited", "digg_count", "comment_count", "share_count", "play_count", "collect_count", "reply_comment_total", "create_time"]

    static func decode(_ data: Data, title: String) throws -> ExploreResult {
        guard let root = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            throw AppError.message("返回内容暂时无法读取，请稍后重试。")
        }
        if let dictionary = root as? [String: Any], let code = int(dictionary["code"]), ![0, 200].contains(code) {
            throw TikHubResponse.error(for: code)
        }
        let payload = (root as? [String: Any])?["data"] ?? root
        if let object = payload as? [String: Any], let code = int(object["status_code"]), code != 0 {
            throw AppError.message("暂未获取到有效结果，请检查查询条件后重试。")
        }
        var sections: [ExploreSection] = []
        collect(payload, path: "result", title: "查询结果", depth: 0, into: &sections)
        let summary: [ExploreValue]
        if let object = payload as? [String: Any] { summary = values(object, limit: 30, depth: 2) }
        else if let scalar = scalar(payload) { summary = [.init(label: "结果", value: scalar)] }
        else { summary = [] }
        let pagination = paginationObject(payload)
        var next: [String: String] = [:]
        for key in ["max_cursor", "cursor", "offset", "search_id", "backtrace", "page"] {
            if let value = pagination[key], let string = scalar(value, allowEmpty: true) { next[key] = string }
        }
        let hasMore = pagination["has_more"].flatMap(bool) ?? pagination["hasMore"].flatMap(bool)
        let formatted = (try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed])) ?? data
        return ExploreResult(title: title, summary: summary, sections: sections, rawJSON: formatted,
                             nextCursor: next["max_cursor"] ?? next["cursor"] ?? next["offset"],
                             hasMore: hasMore, nextPageValues: next)
    }

    private static func collect(_ value: Any, path: String, title: String, depth: Int, into sections: inout [ExploreSection]) {
        guard depth <= 6, sections.count < 20 else { return }
        if let list = value as? [Any] {
            guard !list.isEmpty else { return }
            let rows = list.prefix(100).enumerated().map { index, item -> ExploreRow in
                if var object = item as? [String: Any] {
                    for key in ["aweme_info", "aweme", "item", "user_info", "author_info"] {
                        if let wrapped = object[key] as? [String: Any], !wrapped.isEmpty { object = wrapped; break }
                    }
                    let rowTitle = preferredKeys.compactMap { scalar(object[$0]) }.first ?? "第 \(index + 1) 项"
                    let author = object["author"] as? [String: Any] ?? object["user"] as? [String: Any] ?? object["owner"] as? [String: Any]
                    let subtitle = author.flatMap { scalar($0["nickname"]) } ?? ""
                    return .init(id: "\(path).\(index)", title: String(rowTitle.prefix(500)), subtitle: subtitle,
                                 values: values(object, limit: 30, depth: 2), imageURL: imageURL(object))
                }
                return .init(id: "\(path).\(index)", title: scalar(item) ?? "第 \(index + 1) 项", subtitle: "", values: [], imageURL: nil)
            }
            sections.append(.init(id: path, title: title, rows: rows))
            // Portraits and trends often place the actual values in arrays inside
            // each dimension/series. Keep those readable instead of showing only
            // the dimension ID; the original response remains exportable in full.
            for (index, item) in list.prefix(20).enumerated() {
                guard sections.count < 20, let object = item as? [String: Any] else { continue }
                let parentTitle = preferredKeys.compactMap { scalar(object[$0]) }.first ?? "第 \(index + 1) 项"
                for key in object.keys.sorted() where !hidden.contains(key) && !isMediaKey(key) {
                    let child = object[key]!
                    if child is [Any] || child is [String: Any] {
                        collect(child, path: "\(path).\(index).\(key)", title: parentTitle + " · " + (labels[key] ?? readable(key)), depth: depth + 1, into: &sections)
                    }
                }
            }
        } else if let object = value as? [String: Any] {
            for key in object.keys.sorted() where !hidden.contains(key) && !isMediaKey(key) {
                let child = object[key]!
                if child is [Any] || child is [String: Any] {
                    collect(child, path: path + "." + key, title: labels[key] ?? readable(key), depth: depth + 1, into: &sections)
                }
            }
        }
    }

    private static func values(_ object: [String: Any], limit: Int, depth: Int, prefix: String = "") -> [ExploreValue] {
        var result: [ExploreValue] = []
        let keys = orderedKeys.filter { object[$0] != nil } + object.keys.filter { !orderedKeys.contains($0) }.sorted()
        for key in keys where !hidden.contains(key) && !isMediaKey(key) {
            guard result.count < limit else { break }
            let label = prefix + (labels[key] ?? readable(key))
            if let text = scalar(object[key]) { result.append(.init(label: label, value: String(text.prefix(2000)))) }
            else if let list = object[key] as? [Any], !list.isEmpty, list.allSatisfy({ scalar($0) != nil }) {
                let text = list.prefix(30).compactMap { scalar($0) }.joined(separator: "、")
                result.append(.init(label: label, value: String(text.prefix(2000))))
            }
            else if depth > 0, let child = object[key] as? [String: Any] {
                result.append(contentsOf: values(child, limit: limit - result.count, depth: depth - 1, prefix: label + " · "))
            }
        }
        var seen: Set<String> = []
        return result.filter { seen.insert($0.id).inserted }
    }

    private static func paginationObject(_ value: Any, depth: Int = 0) -> [String: Any] {
        guard depth < 4, let object = value as? [String: Any] else { return [:] }
        if let page = object["pagination"] as? [String: Any] { return page }
        if ["max_cursor", "cursor", "offset", "has_more", "hasMore"].contains(where: { object[$0] != nil }) { return object }
        if let inner = object["data"] { return paginationObject(inner, depth: depth + 1) }
        return [:]
    }

    private static func imageURL(_ object: [String: Any]) -> URL? {
        for key in ["avatar_thumb", "avatar_medium", "avatar", "cover", "origin_cover"] {
            if let raw = object[key] as? String, let url = TikHubResponse.mediaURL(raw) { return url }
            if let image = object[key] as? [String: Any], let raw = (image["url_list"] as? [String])?.first,
               let url = TikHubResponse.mediaURL(raw) { return url }
        }
        if let video = object["video"] as? [String: Any] { return imageURL(video) }
        return nil
    }

    private static func isMediaKey(_ key: String) -> Bool {
        ["video", "images", "image_post_info", "avatar_thumb", "avatar_medium", "avatar_larger", "avatar_large", "avatar", "cover", "origin_cover", "dynamic_cover", "play_addr", "play_addr_265", "play_addr_h264", "download_addr", "url_list", "bit_rate", "stream_url", "video_model"].contains(key)
    }
    private static func readable(_ key: String) -> String { key.replacingOccurrences(of: "_", with: " ") }
    private static func int(_ value: Any?) -> Int? {
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value) }
        return nil
    }
    private static func bool(_ value: Any) -> Bool? {
        if let number = value as? NSNumber { return number.boolValue }
        if let string = value as? String {
            if ["true", "1"].contains(string.lowercased()) { return true }
            if ["false", "0"].contains(string.lowercased()) { return false }
        }
        return nil
    }
    private static func scalar(_ value: Any?, allowEmpty: Bool = false) -> String? {
        guard let value else { return nil }
        if let string = value as? String { return !string.isEmpty || allowEmpty ? string : nil }
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue ? "是" : "否" }
            return number.stringValue
        }
        return nil
    }
}
