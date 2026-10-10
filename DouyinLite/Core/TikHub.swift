import Foundation

struct VideoQuality: Identifiable, Equatable {
    let id: String
    let label: String
    let width: Int?
    let height: Int?
    let byteCount: Int64?
    let bitrate: Int?
    let codec: String?
    let urls: [URL]
}

struct PhotoInfo: Identifiable, Equatable {
    let id: Int
    let imageURLs: [URL]
    let motionURLs: [URL]
    var qualities: [VideoQuality] = []
}

struct VideoInfo: Equatable {
    let id: String
    let title: String
    let author: String
    let coverURL: URL?
    let downloadURLs: [URL]
    let durationSeconds: Double?
    var photos: [PhotoInfo] = []
    var qualities: [VideoQuality] = []
    var isPhotoPost: Bool { !photos.isEmpty }
    var motionCount: Int { photos.filter { !$0.motionURLs.isEmpty }.count }
}

enum AppError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let message): return message }
    }
}

enum Configuration {
    static func apiKey(from text: String) throws -> String {
        for line in text.split(whereSeparator: \.isNewline) {
            let cleaned = line.trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: "\u{feff}")))
            let parts = cleaned.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2,
                  parts[0].trimmingCharacters(in: .whitespaces) == "TIKHUB_API_KEY" else { continue }
            let value = parts[1].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            return try validatedKey(value)
        }
        throw AppError.message("配置文件中没有 TIKHUB_API_KEY。")
    }

    static func validatedKey(_ input: String) throws -> String {
        let key = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !key.contains(where: { $0.isWhitespace || $0.isNewline }),
              key.utf8.count <= 4096, key != "your_tikhub_api_key" else {
            throw AppError.message("请输入有效的 TikHub API Key。")
        }
        return key
    }
}

enum DouyinShareLink {
    static func extract(from text: String) throws -> URL {
        let detector = try NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        for match in detector.matches(in: text, range: range) {
            guard let url = match.url, let host = url.host?.lowercased(),
                  ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
                  url.user == nil, url.password == nil,
                  (url.port == nil || url.port == 443 || url.port == 80),
                  ["douyin.com", "iesdouyin.com"].contains(where: { host == $0 || host.hasSuffix("." + $0) }),
                  var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { continue }
            components.scheme = "https"
            components.port = nil
            components.fragment = nil
            if let normalized = components.url { return normalized }
        }
        throw AppError.message("没有找到抖音链接。请粘贴“分享 → 复制链接”得到的内容。")
    }
}

enum TikHubResponse {
    static func error(for status: Int) -> AppError {
        let message: String
        switch status {
        case 401: message = "TikHub 密钥无效或已过期，请在设置中更换。"
        case 402: message = "TikHub 余额不足，请在账户中充值后重试。"
        case 403: message = "TikHub 拒绝了请求，请检查接口权限或稍后更换网络重试。"
        case 429: message = "请求过于频繁，请稍后再试。"
        case 400, 404, 422: message = "链接无法解析，请检查作品是否公开、链接是否完整。"
        case 500...599: message = "TikHub 暂时无法解析，请稍后再试。"
        default: message = "解析失败（\(status)），请稍后重试。"
        }
        return .message(message)
    }

    static func mediaURL(_ value: String) -> URL? {
        guard var components = URLComponents(string: value),
              ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
              let host = components.host?.lowercased(), host.contains("."),
              !host.contains(":"), components.user == nil, components.password == nil,
              components.port == nil || components.port == 443 || components.port == 80,
              !host.hasSuffix(".local"), !host.hasSuffix(".localhost"),
              !host.allSatisfy({ $0.isNumber || $0 == "." }) else { return nil }
        components.scheme = "https"
        components.port = nil
        return components.url
    }

    static func addressURLs(_ address: Any?) -> [URL] {
        guard let address = address as? [String: Any], let list = address["url_list"] as? [String] else { return [] }
        var result: [URL] = []
        for raw in list {
            if let url = mediaURL(raw), !result.contains(url) { result.append(url) }
        }
        return result
    }

    private struct PlaybackVariant {
        var width: Int?
        var height: Int?
        var byteCount: Int64?
        var bitrate: Int?
        var codec: String?
        var keys: Set<String>
        var urls: [URL]

        func matches(_ other: Self) -> Bool {
            if !keys.isDisjoint(with: other.keys) || !Set(urls).isDisjoint(with: other.urls) { return true }
            // Metadata can join CDN mirrors even when their URLs and asset keys differ.
            // Require a complete quality tuple; unknown values aren't a quality match.
            guard let width, let height, let bitrate, let codec,
                  width == other.width, height == other.height,
                  bitrate == other.bitrate, codec == other.codec else { return false }
            return byteCount == nil || other.byteCount == nil || byteCount == other.byteCount
        }

        mutating func merge(_ other: Self) {
            width = width ?? other.width
            height = height ?? other.height
            byteCount = byteCount ?? other.byteCount
            bitrate = bitrate ?? other.bitrate
            codec = codec ?? other.codec
            keys.formUnion(other.keys)
            urls = TikHubResponse.uniqueURLs(urls + other.urls)
        }
    }

    private static func positiveInt64(_ value: Any?) -> Int64? {
        let integer: Int64?
        if let text = value as? String { integer = Int64(text) }
        else if let number = value as? NSNumber { integer = Int64(number.stringValue) }
        else { integer = nil }
        return integer.flatMap { $0 > 0 ? $0 : nil }
    }

    private static func positiveInt(_ value: Any?) -> Int? {
        positiveInt64(value).flatMap(Int.init(exactly:))
    }

    private static func uniqueURLs(_ urls: [URL]) -> [URL] {
        var seen = Set<URL>()
        return urls.filter { seen.insert($0).inserted }
    }

    private static func codec(in metadata: [String: Any], address: [String: Any], field: String) -> String? {
        let explicit = (metadata["codec"] as? String) ?? (metadata["codec_name"] as? String)
        let hint = [explicit ?? "", address["url_key"] as? String ?? "", field].joined(separator: " ").lowercased()
        if positiveInt(metadata["is_h265"]) != nil || positiveInt(metadata["is_bytevc1"]) != nil ||
            ["h265", "h.265", "hevc", "hvc1", "hev1", "bytevc1", "play_addr_265"].contains(where: hint.contains) {
            return "HEVC"
        }
        if ["h264", "h.264", "avc1"].contains(where: hint.contains) { return "H.264" }
        if let explicit, !explicit.isEmpty { return explicit }
        return nil
    }

    private static func qualityLabel(width: Int?, height: Int?, bitrate: Int?, codec: String?, original: Bool = false) -> String {
        var parts: [String] = original ? ["原画"] : []
        if let width, let height { parts.append("\(width) × \(height)") }
        else if !original { parts.append("默认画质") }
        if let bitrate {
            parts.append(String(format: "%.2f Mbps", Double(bitrate) / 1_000_000))
        }
        if let codec { parts.append(codec) }
        return parts.joined(separator: " · ")
    }

    static func playbackQualities(_ video: [String: Any]) -> [VideoQuality] {
        var variants: [PlaybackVariant] = []
        func appendAddresses(_ metadata: [String: Any]) {
            // download_addr is deliberately excluded: it may contain a platform watermark.
            let fields = metadata.keys.filter { $0 == "play_addr" || $0.hasPrefix("play_addr_") }.sorted()
            for field in fields {
                guard let address = metadata[field] as? [String: Any] else { continue }
                let urls = addressURLs(address)
                guard !urls.isEmpty else { continue }
                let keys = Set(["url_key", "file_hash"].compactMap { key -> String? in
                    guard let value = address[key] as? String, !value.isEmpty else { return nil }
                    return "\(key):\(value)"
                })
                let candidate = PlaybackVariant(
                    width: positiveInt(address["width"]) ?? positiveInt(metadata["width"]),
                    height: positiveInt(address["height"]) ?? positiveInt(metadata["height"]),
                    byteCount: positiveInt64(address["data_size"]),
                    bitrate: positiveInt(metadata["bit_rate"]) ?? positiveInt(address["bit_rate"]),
                    codec: codec(in: metadata, address: address, field: field),
                    keys: keys, urls: urls
                )
                var merged = candidate
                var index = 0
                while index < variants.count {
                    if variants[index].matches(merged) {
                        var previous = variants.remove(at: index)
                        previous.merge(merged)
                        merged = previous
                        index = 0
                    } else { index += 1 }
                }
                variants.append(merged)
            }
        }
        for rate in video["bit_rate"] as? [[String: Any]] ?? [] { appendAddresses(rate) }
        appendAddresses(video)
        variants.sort {
            let lhsPixels = Double($0.width ?? 0) * Double($0.height ?? 0)
            let rhsPixels = Double($1.width ?? 0) * Double($1.height ?? 0)
            if lhsPixels != rhsPixels { return lhsPixels > rhsPixels }
            if $0.bitrate != $1.bitrate { return ($0.bitrate ?? 0) > ($1.bitrate ?? 0) }
            if $0.byteCount != $1.byteCount { return ($0.byteCount ?? 0) > ($1.byteCount ?? 0) }
            return ($0.urls.first?.absoluteString ?? "") < ($1.urls.first?.absoluteString ?? "")
        }
        return variants.enumerated().map { index, variant in
            VideoQuality(id: "playback-\(index)",
                         label: qualityLabel(width: variant.width, height: variant.height, bitrate: variant.bitrate, codec: variant.codec),
                         width: variant.width, height: variant.height, byteCount: variant.byteCount,
                         bitrate: variant.bitrate, codec: variant.codec, urls: variant.urls)
        }
    }

    static func playbackURLs(_ video: [String: Any]) -> [URL] {
        uniqueURLs(playbackQualities(video).flatMap(\.urls))
    }

    static func decodeOriginal(_ data: Data, status: Int) throws -> VideoQuality {
        guard (200..<300).contains(status) else { throw error(for: status) }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AppError.message("TikHub 返回了无法识别的原画数据。")
        }
        if let code = root["code"] as? Int, code != 200 { throw error(for: code) }
        guard let payload = root["data"] as? [String: Any],
              let rawURL = payload["original_video_url"] as? String,
              let url = mediaURL(rawURL) else {
            throw AppError.message("接口未返回可用的原画地址，普通画质仍可使用。")
        }
        // This endpoint has its own response contract. Never substitute a regular
        // playback/download address and present it as the original upload.
        let metadata = payload["video_data"] as? [String: Any] ?? [:]
        let width = positiveInt(metadata["width"])
        let height = positiveInt(metadata["height"])
        let byteCount = positiveInt64(metadata["data_size"]) ?? positiveInt64(metadata["size"])
        let bitrate = positiveInt(metadata["bit_rate"]) ?? positiveInt(metadata["bitrate"])
        let codec = codec(in: metadata, address: [:], field: "")
        return VideoQuality(id: "original", label: qualityLabel(width: width, height: height, bitrate: bitrate, codec: codec, original: true),
                            width: width, height: height, byteCount: byteCount, bitrate: bitrate, codec: codec, urls: [url])
    }

    static func decode(_ data: Data, status: Int) throws -> VideoInfo {
        guard (200..<300).contains(status) else { throw error(for: status) }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AppError.message("TikHub 返回了无法识别的内容，请稍后重试。")
        }
        if let code = root["code"] as? Int, code != 200 { throw error(for: code) }
        guard let payload = root["data"] as? [String: Any] else {
            throw AppError.message("未获取到作品，请检查链接或作品的公开状态。")
        }
        let detail = (payload["aweme_detail"] as? [String: Any])
            ?? (payload["aweme_details"] as? [[String: Any]])?.first
            ?? (payload["aweme_list"] as? [[String: Any]])?.first
            ?? (payload["aweme_id"] != nil ? payload : nil)
        guard let detail else {
            throw AppError.message("该作品已删除、设为私密或暂时无法访问。")
        }
        let author = detail["author"] as? [String: Any]
        let id = (detail["aweme_id"] as? String) ?? (detail["aweme_id"] as? NSNumber)?.stringValue ?? UUID().uuidString
        let title = (detail["desc"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let webImages = detail["images"] as? [[String: Any]] ?? []
        let appImages = (detail["image_post_info"] as? [String: Any])?["images"] as? [[String: Any]] ?? []
        let images = webImages.isEmpty ? appImages : webImages
        if !images.isEmpty {
            let photos = images.enumerated().map { index, item in
                let direct = addressURLs(item)
                let imageURLs = direct.isEmpty ? addressURLs(item["display_image"]) : direct
                let qualities = (item["video"] as? [String: Any]).map(playbackQualities) ?? []
                let motion = uniqueURLs(qualities.flatMap(\.urls))
                return PhotoInfo(id: index, imageURLs: imageURLs, motionURLs: motion, qualities: qualities)
            }
            guard photos.allSatisfy({ !$0.imageURLs.isEmpty }) else {
                throw AppError.message("接口未返回完整的图片地址，请稍后重新获取。")
            }
            return VideoInfo(id: id, title: title.isEmpty ? "抖音图文" : title,
                             author: author?["nickname"] as? String ?? "",
                             coverURL: photos.first?.imageURLs.first, downloadURLs: [],
                             durationSeconds: nil, photos: photos)
        }
        guard let video = detail["video"] as? [String: Any] else {
            throw AppError.message("这个作品没有可下载的视频。")
        }
        // Playback variants are normal CDN qualities, not the paid original-upload endpoint.
        let qualities = playbackQualities(video)
        let urls = uniqueURLs(qualities.flatMap(\.urls))
        guard !urls.isEmpty else { throw AppError.message("没有找到可用的视频地址，请稍后重新解析。") }
        let cover = video["cover"] as? [String: Any]
        let coverURL = (cover?["url_list"] as? [String])?.compactMap(mediaURL).first
        return VideoInfo(id: id, title: title.isEmpty ? "抖音视频" : title,
                         author: author?["nickname"] as? String ?? "", coverURL: coverURL,
                         downloadURLs: urls,
                         durationSeconds: (video["duration"] as? NSNumber).map { $0.doubleValue / 1000 },
                         qualities: qualities)
    }
}

final class APIRedirectPolicy: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        // Never send the credential to a different host via a redirect.
        completionHandler(request.url?.scheme == "https" && request.url?.host == "api.tikhub.io" ? request : nil)
    }
}

struct TikHubService {
    func resolve(_ shareURL: URL, apiKey: String) async throws -> VideoInfo {
        let (data, status) = try await response(shareURL, apiKey: apiKey)
        return try TikHubResponse.decode(data, status: status)
    }

    func response(_ shareURL: URL, apiKey: String) async throws -> (Data, Int) {
        var components = URLComponents(string: "https://api.tikhub.io/api/v1/douyin/web/fetch_one_video_by_share_url")!
        components.queryItems = [URLQueryItem(name: "share_url", value: shareURL.absoluteString)]
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 60
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("DouyinLite/1.1 (iOS)", forHTTPHeaderField: "User-Agent")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: configuration, delegate: APIRedirectPolicy(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }
}
