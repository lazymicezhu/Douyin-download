import Foundation
import AVFoundation
import Darwin
import ImageIO

@main
struct CoreTests {
    static var passed = 0
    static func check(_ name: String, _ condition: Bool) throws {
        guard condition else { throw AppError.message("FAIL: \(name)") }
        passed += 1
        print("PASS: \(name)")
    }
    static func expectFailure(_ name: String, _ block: () throws -> Void) throws {
        do { try block() } catch { try check(name, true); return }
        try check(name, false)
    }
    static func json(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object)
    }

    static func main() async throws {
        if CommandLine.arguments.count >= 3 && ["--live", "--inspect", "--fixture"].contains(CommandLine.arguments[1]) {
          do {
            let data: Data
            let responseStatus: Int
            if CommandLine.arguments[1] == "--fixture" {
                data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]))
                responseStatus = 200
            } else {
                let key = try Configuration.apiKey(from: String(contentsOfFile: ".env", encoding: .utf8))
                let url = try DouyinShareLink.extract(from: CommandLine.arguments[2])
                (data, responseStatus) = try await TikHubService().response(url, apiKey: key)
                let sanitized = String(decoding: data, as: UTF8.self).replacingOccurrences(of: key, with: "[REDACTED]")
                try sanitized.write(toFile: "build/observed-response.json", atomically: true, encoding: .utf8)
            }
            let video = try TikHubResponse.decode(data, status: responseStatus)
            print("LIVE: resolved post \(video.id); \(video.photos.count) images; \(video.motionCount) motion clips; \(video.downloadURLs.count) video candidates")
            if CommandLine.arguments[1] == "--inspect" { return }
            let folder = URL(fileURLWithPath: "build/LiveValidation", isDirectory: true)
            if video.isPhotoPost {
                for photo in video.photos {
                    let image = try await ImageDownloader.download(photo, to: folder)
                    let source = CGImageSourceCreateWithURL(image as CFURL, nil)!
                    let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
                    print("LIVE: image \(photo.id + 1); \(props[kCGImagePropertyPixelWidth] ?? 0)x\(props[kCGImagePropertyPixelHeight] ?? 0)")
                    try FileManager.default.removeItem(at: image)
                    if !photo.motionURLs.isEmpty {
                        let motion = try await VideoDownloader.download(urls: photo.motionURLs, to: folder)
                        let duration = try await AVURLAsset(url: motion).load(.duration).seconds
                        print("LIVE: motion \(photo.id + 1); \(String(format: "%.1f", duration)) seconds; playable")
                        try FileManager.default.removeItem(at: motion)
                    }
                }
                return
            }
            let file = try await VideoDownloader.download(video, to: folder)
            let duration = try await AVURLAsset(url: file).load(.duration).seconds
            let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            print("LIVE: downloaded playable MP4; \(size) bytes; \(String(format: "%.1f", duration)) seconds")
            try FileManager.default.removeItem(at: file)
            return
          } catch {
            print("LIVE FAILED: \(error.localizedDescription)")
            exit(1)
          }
        }
        try check("env preserves base64 padding", Configuration.apiKey(from: "# settings\nTIKHUB_API_KEY='abc+def/ghi=='\n") == "abc+def/ghi==")
        try expectFailure("missing env key rejected") { _ = try Configuration.apiKey(from: "OTHER_KEY=123") }
        try expectFailure("header injection rejected") { _ = try Configuration.validatedKey("abc\r\nX-Test: injected") }
        let share = try DouyinShareLink.extract(from: "3.14 复制此链接打开抖音 https://v.douyin.com/abcdef/ 这是一段文案")
        try check("share text extracts only URL", share.absoluteString == "https://v.douyin.com/abcdef/")
        try expectFailure("lookalike hostname rejected") { _ = try DouyinShareLink.extract(from: "https://douyin.com.attacker.example/video/123") }
        try expectFailure("credentials in URL rejected") { _ = try DouyinShareLink.extract(from: "https://user:pass@v.douyin.com/abc/") }
        try expectFailure("empty input rejected") { _ = try DouyinShareLink.extract(from: " ") }
        let detail: [String: Any] = ["aweme_id": "123", "desc": "Test video", "author": ["nickname": "Tester"], "video": [
            "duration": 15000, "play_addr_h264": ["url_list": ["https://media.example/h264.mp4"]],
            "play_addr": ["url_list": ["https://media.example/h264.mp4", "https://media.example/second.mp4"]],
            "download_addr": ["url_list": ["https://media.example/watermarked.mp4"]]]]
        let video = try TikHubResponse.decode(json(["code": 200, "data": ["aweme_detail": detail]]), status: 200)
        try check("real Web response nesting", video.id == "123" && video.author == "Tester")
        try check("duration converted to seconds", video.durationSeconds == 15)
        try check("URLs deduplicated and watermark address excluded", video.downloadURLs.count == 2 && !video.downloadURLs.contains(where: { $0.absoluteString.contains("watermarked") }))
        try expectFailure("HTTP 200 with inaccessible content rejected") { _ = try TikHubResponse.decode(json(["code": 200, "data": ["filter_detail": ["detail_msg": "private"]]]), status: 200) }
        try expectFailure("HTTP authentication error rejected") { _ = try TikHubResponse.decode(Data(), status: 401) }
        try expectFailure("API-level balance error rejected") { _ = try TikHubResponse.decode(json(["code": 402, "data": NSNull()]), status: 200) }
        try expectFailure("HTML error page rejected") { _ = try TikHubResponse.decode(Data("<html>error</html>".utf8), status: 200) }
        var photoDetail = detail
        photoDetail["images"] = [["url_list": ["https://media.example/image.jpg"]]]
        let photos = try TikHubResponse.decode(json(["code": 200, "data": ["aweme_detail": photoDetail]]), status: 200)
        try check("image post parsed without downloading slideshow video", photos.isPhotoPost && photos.photos.count == 1 && photos.downloadURLs.isEmpty)
        photoDetail["images"] = [
            ["url_list": ["https://media.example/1.jpg"], "video": ["play_addr": ["url_list": ["https://media.example/live.mp4"]]]],
            ["url_list": ["https://media.example/2.jpg"]]
        ]
        let mixed = try TikHubResponse.decode(json(["code": 200, "data": ["aweme_details": [photoDetail]]]), status: 200)
        try check("App plural details response accepted", mixed.id == "123")
        try check("mixed live and still images retain pairing", mixed.photos.count == 2 && mixed.photos[0].motionURLs.count == 1 && mixed.photos[1].motionURLs.isEmpty)
        photoDetail.removeValue(forKey: "images")
        photoDetail["image_post_info"] = ["images": [["url_list": ["https://media.example/app.jpg"]]]]
        let nested = try TikHubResponse.decode(json(["code": 200, "data": ["aweme_detail": photoDetail]]), status: 200)
        try check("nested image_post_info supported", nested.photos.count == 1)
        photoDetail["images"] = [["url_list": []]]
        try expectFailure("missing image URLs cannot silently drop a photo") { _ = try TikHubResponse.decode(json(["code": 200, "data": ["aweme_detail": photoDetail]]), status: 200) }
        try check("Windows text configuration BOM supported", Configuration.apiKey(from: "\u{feff}TIKHUB_API_KEY=abc==\r\n") == "abc==")
        try check("non-network media schemes rejected", TikHubResponse.mediaURL("file:///etc/passwd") == nil)
        try check("private IP media rejected", TikHubResponse.mediaURL("https://127.0.0.1/video.mp4") == nil)
        try check("media connections upgraded to HTTPS", TikHubResponse.mediaURL("http://media.example/a.mp4?sign=abc%2Bdef")?.absoluteString == "https://media.example/a.mp4?sign=abc%2Bdef")
        print("\(passed) checks passed.")
    }
}
