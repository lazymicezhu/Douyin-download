import Foundation
import AVFoundation

enum VideoDownloader {
    static func download(_ video: VideoInfo, to folder: URL) async throws -> URL {
        try await download(urls: video.downloadURLs, to: folder)
    }

    static func download(urls: [URL], to folder: URL) async throws -> URL {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForResource = 300
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // Media requests intentionally have no TikHub credential header.
        for candidate in urls.prefix(9) {
            try Task.checkCancellation()
            var request = URLRequest(url: candidate)
            request.timeoutInterval = 60
            request.setValue("https://www.douyin.com/", forHTTPHeaderField: "Referer")
            request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 Mobile/15E148", forHTTPHeaderField: "User-Agent")
            do {
                let (temporary, response) = try await session.download(for: request)
                defer { try? FileManager.default.removeItem(at: temporary) }
                try Task.checkCancellation()
                guard let response = response as? HTTPURLResponse, response.statusCode == 200 else { continue }
                let handle = try FileHandle(forReadingFrom: temporary)
                let header = try handle.read(upToCount: 32) ?? Data()
                try handle.close()
                guard header.count >= 12, String(data: header[4..<8], encoding: .ascii) == "ftyp" else { continue }
                let destination = folder.appendingPathComponent("抖音-\(UUID().uuidString.prefix(8)).mp4")
                try FileManager.default.moveItem(at: temporary, to: destination)
                do {
                    guard try await AVURLAsset(url: destination).load(.isPlayable) else {
                        try? FileManager.default.removeItem(at: destination)
                        continue
                    }
                    try Task.checkCancellation()
                    return destination
                } catch {
                    try? FileManager.default.removeItem(at: destination)
                    throw error
                }
            } catch is CancellationError { throw CancellationError() }
            catch let error as URLError where error.code == .cancelled { throw error }
            catch { continue }
        }
        throw AppError.message("视频下载失败，地址可能已过期。请点击“获取作品”重新解析后再保存。")
    }
}
