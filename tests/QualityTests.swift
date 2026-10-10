import Foundation

@main
struct QualityTests {
    static var passed = 0

    static func check(_ name: String, _ result: Bool) throws {
        guard result else { throw AppError.message("FAIL: \(name)") }
        passed += 1
        print("PASS: \(name)")
    }

    static func json(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object)
    }

    static func expectFailure(_ name: String, _ operation: () throws -> Void) throws {
        do { try operation() } catch { try check(name, true); return }
        try check(name, false)
    }

    static func main() throws {
        let source: [String: Any] = [
            "bit_rate": [
                ["bit_rate": 8_000_000, "play_addr": ["width": 1280, "height": 720, "url_key": "asset_h264_720p", "data_size": 10000,
                    "url_list": ["https://cdn.example/720.mp4"]]],
                ["bit_rate": 2_000_000, "is_h265": 1, "play_addr": ["width": 1080, "height": 1920, "url_key": "asset_h265_1080p", "data_size": 20000,
                    "url_list": ["https://cdn.example/1080-hevc.mp4", "https://mirror.example/1080-hevc.mp4"]]],
                ["bit_rate": 3_000_000, "play_addr": ["width": 1080, "height": 1920, "url_key": "asset_h264_1080p", "data_size": 30000,
                    "url_list": ["https://cdn.example/1080-h264.mp4"]]],
                ["bit_rate": 3_000_000, "codec": "h264", "play_addr": ["width": 1080, "height": 1920, "data_size": 30000,
                    "url_list": ["https://mirror.example/1080-h264.mp4"]]]
            ],
            "play_addr_h264": ["width": 1080, "height": 1920, "url_key": "asset_h264_1080p", "data_size": 30000,
                "url_list": ["https://cdn.example/1080-h264.mp4", "https://third.example/1080-h264.mp4"]],
            "download_addr": ["url_list": ["https://cdn.example/watermarked.mp4"]]
        ]
        let qualities = TikHubResponse.playbackQualities(source)
        try check("mirrors and top-level duplicate addresses form one quality", qualities.count == 3 && qualities[0].urls.count == 3)
        try check("resolution has priority over bitrate", qualities[0].height == 1920 && qualities.last?.height == 720)
        try check("same resolution is ordered by bitrate", qualities[0].bitrate == 3_000_000 && qualities[1].bitrate == 2_000_000)
        try check("HEVC preserved and labelled", qualities[1].codec == "HEVC" && qualities[1].label.contains("HEVC"))
        try check("source byte size preserved", qualities[0].byteCount == 30000)
        try check("watermarked download address never included", !qualities.flatMap(\.urls).contains { $0.path.contains("watermarked") })
        try check("quality IDs are unique", Set(qualities.map(\.id)).count == qualities.count)

        let unknown = TikHubResponse.playbackQualities(["play_addr": ["url_list": ["https://cdn.example/unknown.mp4", "http://cdn.example/unknown.mp4"]]])
        try check("unknown metadata stays unknown; HTTPS mirrors deduplicate", unknown.count == 1 && unknown[0].width == nil && unknown[0].height == nil && unknown[0].codec == nil && unknown[0].urls.count == 1)

        let video = try TikHubResponse.decode(json(["code": 200, "data": ["aweme_detail": ["aweme_id": "123", "video": source]]]), status: 200)
        try check("ordinary video exposes sorted qualities", video.qualities == qualities && video.downloadURLs.first == qualities[0].urls.first)

        let original = try TikHubResponse.decodeOriginal(json(["code": 200, "data": [
            "original_video_url": "https://cdn.example/original.mp4", "video_data": ["width": "2160", "height": 3840, "data_size": "9000000", "bit_rate": 10_000_000, "codec": "hevc"]
        ]]), status: 200)
        try check("dedicated original contract decoded", original.id == "original" && original.width == 2160 && original.height == 3840 && original.byteCount == 9_000_000 && original.codec == "HEVC")
        let noMetadata = try TikHubResponse.decodeOriginal(json(["code": 200, "data": ["original_video_url": "https://cdn.example/original.mp4"]]), status: 200)
        try check("original dimensions are never invented", noMetadata.width == nil && noMetadata.height == nil && noMetadata.bitrate == nil && noMetadata.byteCount == nil)
        try expectFailure("ordinary playback cannot masquerade as original") {
            _ = try TikHubResponse.decodeOriginal(json(["code": 200, "data": ["video_data": source]]), status: 200)
        }
        try expectFailure("invalid original media URL rejected") {
            _ = try TikHubResponse.decodeOriginal(json(["code": 200, "data": ["original_video_url": "file:///tmp/video.mp4"]]), status: 200)
        }
        try expectFailure("original API-level error respected") {
            _ = try TikHubResponse.decodeOriginal(json(["code": 402, "data": NSNull()]), status: 200)
        }
        try expectFailure("original HTTP error respected") {
            _ = try TikHubResponse.decodeOriginal(Data(), status: 401)
        }

        let fixtureURL = URL(fileURLWithPath: "build/observed-response.json")
        if FileManager.default.fileExists(atPath: fixtureURL.path) {
            let observed = try TikHubResponse.decode(Data(contentsOf: fixtureURL), status: 200)
            try check("observed live photo retains one image and motion pairing", observed.photos.count == 1 && observed.motionCount == 1)
            let motion = observed.photos[0].qualities
            try check("observed repeated addresses collapse to one 720p quality", motion.count == 1 && motion[0].width == 1280 && motion[0].height == 720)
            try check("observed bitrate and file size retained", motion[0].bitrate == 949196 && motion[0].byteCount == 470683)
            try check("observed three CDN mirrors remain within one quality", motion[0].urls.count == 3 && observed.photos[0].motionURLs == motion[0].urls)
        }
        print("\(passed) quality checks passed; no network requests made.")
    }
}
