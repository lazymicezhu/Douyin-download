import Foundation

/// Both the document picker and “Open in 抖取” use the same bounded, coordinated read.
enum ConfigurationFileReader {
    private static let byteLimit = 65_536

    static func readKey(from url: URL) async throws -> String {
        guard url.isFileURL else { throw AppError.message("请选择保存在“文件”中的配置文件。") }
        let operation = CoordinatedConfigurationRead(url: url, byteLimit: byteLimit)
        let task = Task.detached(priority: .userInitiated) { try operation.read() }
        let data = try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
            operation.cancel()
        }
        try Task.checkCancellation()
        return try key(from: decode(data))
    }

    /// Accept a bare key or a complete env file. Never include pasted content in errors.
    static func key(from input: String) throws -> String {
        guard input.utf8.count <= byteLimit else {
            throw AppError.message("配置内容超过 64 KB，请仅粘贴 API Key 或对应的配置行。")
        }
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{feff}")))
        guard !text.isEmpty else { throw AppError.message("配置内容为空，请复制 API Key 或配置文件中的文字。") }
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }

        for rawLine in lines {
            let line = rawLine.hasPrefix("export ") ? String(rawLine.dropFirst(7)).trimmingCharacters(in: .whitespaces) : rawLine
            let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces) == "TIKHUB_API_KEY" else { continue }
            return try Configuration.validatedKey(unquote(String(parts[1])))
        }
        guard lines.count == 1, !text.contains("TIKHUB_API_KEY"), !text.hasPrefix("#") else {
            throw AppError.message("未找到 TIKHUB_API_KEY=… 配置行。也可以直接粘贴 API Key 本身。")
        }
        return try Configuration.validatedKey(unquote(text))
    }

    private static func unquote(_ input: String) -> String {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if let quote = value.first, quote == "\"" || quote == "'",
           value.count >= 2, value.last == quote {
            return String(value.dropFirst().dropLast())
        }
        return value
    }

    private static func decode(_ data: Data) throws -> String {
        guard !data.isEmpty else { throw AppError.message("选中的配置文件是空文件。") }
        let encoding: String.Encoding
        if data.starts(with: [0xff, 0xfe, 0x00, 0x00]) || data.starts(with: [0x00, 0x00, 0xfe, 0xff]) {
            encoding = .utf32
        } else if data.starts(with: [0xff, 0xfe]) || data.starts(with: [0xfe, 0xff]) {
            encoding = .utf16
        } else {
            encoding = .utf8
        }
        guard let text = String(data: data, encoding: encoding),
              !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) && $0 != "\n" && $0 != "\r" && $0 != "\t" }) else {
            throw AppError.message("已打开文件，但它不是可读取的文本配置。请选择原始 TikHub.env / TikHub.txt，或直接粘贴 API Key。支持 UTF-8 和带标记的 UTF-16 文本。")
        }
        return text
    }
}

private final class CoordinatedConfigurationRead: @unchecked Sendable {
    private let url: URL
    private let byteLimit: Int
    private let coordinator = NSFileCoordinator()

    init(url: URL, byteLimit: Int) {
        self.url = url
        self.byteLimit = byteLimit
    }

    func cancel() { coordinator.cancel() }

    func read() throws -> Data {
        try Task.checkCancellation()
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        var coordinationError: NSError?
        var result: Result<Data, Error>?

        // The default coordinated read materializes iCloud/provider files before access.
        // It must stay off the main thread because that download can take time.
        coordinator.coordinate(readingItemAt: url, options: [], error: &coordinationError) { readableURL in
            result = Result {
                try Task.checkCancellation()
                let values = try readableURL.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
                guard values.isDirectory != true else { throw AppError.message("选中的是文件夹，请选择其中的配置文件。") }
                if let size = values.fileSize, size > self.byteLimit {
                    throw AppError.message("配置文件超过 64 KB，请选择 TikHub.env 或 TikHub.txt。")
                }
                let handle = try FileHandle(forReadingFrom: readableURL)
                defer { try? handle.close() }
                var data = Data()
                while data.count <= self.byteLimit {
                    try Task.checkCancellation()
                    let part = try handle.read(upToCount: min(8_192, self.byteLimit + 1 - data.count)) ?? Data()
                    if part.isEmpty { break }
                    data.append(part)
                }
                guard data.count <= self.byteLimit else { throw AppError.message("配置文件超过 64 KB，请选择 TikHub.env 或 TikHub.txt。") }
                try Task.checkCancellation()
                return data
            }
        }
        try Task.checkCancellation()
        do {
            if let coordinationError { throw coordinationError }
            guard let result else { throw AppError.message("文件提供方未交付配置内容，请先在“文件”中下载该文件，再重试。") }
            return try result.get()
        } catch let error as AppError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            let failure = error as NSError
            if failure.domain == NSCocoaErrorDomain, failure.code == NSFileReadNoPermissionError {
                throw AppError.message("系统未允许读取这个文件。请用“导入配置文件”重新选择；也可复制文件中的文字，再点“粘贴并保存”。（读取权限错误 \(failure.code)）")
            }
            if failure.domain == NSCocoaErrorDomain, failure.code == NSFileReadNoSuchFileError || failure.code == NSFileNoSuchFileError {
                throw AppError.message("文件还未下载到手机，或已被移动。请在“文件”中长按文件并选“立即下载”，再重新导入。（读取错误 \(failure.code)）")
            }
            throw AppError.message("文件读取失败，请在“文件”中确认它已下载到手机，或改用粘贴配置。错误：\(failure.domain) / \(failure.code)。")
        }
    }
}
