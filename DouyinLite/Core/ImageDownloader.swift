import Foundation
import ImageIO
import UniformTypeIdentifiers

enum ImageDownloader {
    static func download(_ photo: PhotoInfo, to folder: URL) async throws -> URL {
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for url in photo.imageURLs.prefix(4) {
            try Task.checkCancellation()
            var request = URLRequest(url: url)
            request.timeoutInterval = 45
            request.setValue("https://www.douyin.com/", forHTTPHeaderField: "Referer")
            request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 Mobile/15E148", forHTTPHeaderField: "User-Agent")
            do {
                let (temporary, response) = try await session.download(for: request)
                defer { try? FileManager.default.removeItem(at: temporary) }
                try Task.checkCancellation()
                guard (response as? HTTPURLResponse)?.statusCode == 200,
                      let source = CGImageSourceCreateWithURL(temporary as CFURL, nil),
                      CGImageSourceGetCount(source) > 0,
                      let typeID = CGImageSourceGetType(source),
                      let type = UTType(typeID as String) else { continue }
                let name = String(format: "图片-%02d-%@", photo.id + 1, String(UUID().uuidString.prefix(6)))
                if [UTType.jpeg, .png, .heic, .heif].contains(type) {
                    let destination = folder.appendingPathComponent(name).appendingPathExtension(type.preferredFilenameExtension ?? "jpg")
                    // Keep supported originals byte-for-byte, at their original resolution.
                    guard CGImageSourceCreateImageAtIndex(source, 0, nil) != nil else { continue }
                    try FileManager.default.moveItem(at: temporary, to: destination)
                    return destination
                }
                // Some Douyin images are WebP: losslessly convert the decoded pixels to PNG for Photos.
                let destination = folder.appendingPathComponent(name).appendingPathExtension("png")
                guard let output = CGImageDestinationCreateWithURL(destination as CFURL, UTType.png.identifier as CFString, 1, nil) else { continue }
                CGImageDestinationAddImageFromSource(output, source, 0, nil)
                guard CGImageDestinationFinalize(output) else {
                    try? FileManager.default.removeItem(at: destination)
                    continue
                }
                return destination
            } catch is CancellationError { throw CancellationError() }
            catch let error as URLError where error.code == .cancelled { throw error }
            catch { continue }
        }
        throw AppError.message("第 \(photo.id + 1) 张图片下载失败。请重试，或重新获取作品。")
    }
}
