import Foundation
import AVFoundation
import CoreMedia
import ImageIO
import Photos
import UniformTypeIdentifiers
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

struct LivePhotoFiles: Sendable {
    let photoURL: URL
    let pairedVideoURL: URL
}

/// Creates actual Photos resources: a JPEG and a MOV sharing a content identifier,
/// plus the timed still-image metadata track required by Live Photos.
enum LivePhotoBuilder {
    private static let contentKey = "com.apple.quicktime.content.identifier"
    private static let stillKey = "com.apple.quicktime.still-image-time"

    static func build(photo: URL, video: URL, in folder: URL) async throws -> LivePhotoFiles {
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let identifier = UUID().uuidString
        let files = LivePhotoFiles(
            photoURL: folder.appendingPathComponent("Live-\(identifier).jpg"),
            pairedVideoURL: folder.appendingPathComponent("Live-\(identifier).mov")
        )
        var completed = false
        defer {
            if !completed {
                try? FileManager.default.removeItem(at: files.photoURL)
                try? FileManager.default.removeItem(at: files.pairedVideoURL)
            }
        }
        try writePhoto(photo, to: files.photoURL, identifier: identifier)
        try Task.checkCancellation()
        try await writeMovie(video, to: files.pairedVideoURL, identifier: identifier)
        try Task.checkCancellation()
        try await validate(files)
        try Task.checkCancellation()
        completed = true
        return files
    }

    private static func writePhoto(_ sourceURL: URL, to destinationURL: URL, identifier: String) throws {
        guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
              CGImageSourceGetCount(source) > 0,
              CGImageSourceCreateImageAtIndex(source, 0, nil) != nil,
              let destination = CGImageDestinationCreateWithURL(
                destinationURL as CFURL, UTType.jpeg.identifier as CFString, 1, nil
              ) else { throw BuildError.message("无法读取实况照片的静态图片。") }

        // Keep full-resolution pixels, EXIF orientation and existing photographic metadata.
        var properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] ?? [:]
        var maker = properties[kCGImagePropertyMakerAppleDictionary as String] as? [String: Any] ?? [:]
        maker["17"] = identifier
        properties[kCGImagePropertyMakerAppleDictionary as String] = maker
        properties[kCGImageDestinationLossyCompressionQuality as String] = 1.0
        CGImageDestinationAddImageFromSource(destination, source, 0, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination),
              let saved = CGImageSourceCreateWithURL(destinationURL as CFURL, nil),
              let savedProperties = CGImageSourceCopyPropertiesAtIndex(saved, 0, nil) as? [String: Any],
              let savedMaker = savedProperties[kCGImagePropertyMakerAppleDictionary as String] as? [String: Any],
              savedMaker["17"] as? String == identifier else {
            throw BuildError.message("无法写入实况照片配对信息。")
        }
    }

    private static func writeMovie(_ sourceURL: URL, to destinationURL: URL, identifier: String) async throws {
        let asset = AVURLAsset(url: sourceURL)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard let videoTrack = videoTracks.first else {
            throw BuildError.message("实况片段没有可用的视频轨道。")
        }
        let videoRange = try await videoTrack.load(.timeRange)
        guard videoRange.start.isNumeric, videoRange.duration.isNumeric,
              videoRange.duration.seconds > 0 else {
            throw BuildError.message("实况片段的时长无效。")
        }
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let reader = try AVAssetReader(asset: asset)
        let writer = try AVAssetWriter(outputURL: destinationURL, fileType: .mov)
        var finished = false
        defer {
            if !finished {
                reader.cancelReading()
                writer.cancelWriting()
            }
        }

        // Compressed sample passthrough preserves resolution, codec, HDR and sound.
        // The transform belongs to the track, not the encoded pixels.
        var channels: [MediaChannel] = []
        for track in [videoTrack] + audioTracks {
            try Task.checkCancellation()
            let formats = try await track.load(.formatDescriptions)
            guard let format = formats.first else {
                throw BuildError.message("无法识别实况片段的媒体格式。")
            }
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            output.alwaysCopiesSampleData = false
            let input = AVAssetWriterInput(mediaType: track.mediaType, outputSettings: nil, sourceFormatHint: format)
            input.expectsMediaDataInRealTime = false
            if track.mediaType == .video { input.transform = try await track.load(.preferredTransform) }
            guard reader.canAdd(output), writer.canAdd(input) else {
                throw BuildError.message("此实况片段的编码暂不支持保存为 Live Photo。")
            }
            reader.add(output)
            writer.add(input)
            channels.append(MediaChannel(output: output, input: input))
        }

        let content = AVMutableMetadataItem()
        content.key = contentKey as NSString
        content.keySpace = .quickTimeMetadata
        content.value = identifier as NSString
        content.dataType = kCMMetadataBaseDataType_UTF8 as String
        writer.metadata = [content]

        let metadata = try makeMetadataAdaptor()
        guard writer.canAdd(metadata.assetWriterInput) else {
            throw BuildError.message("无法创建实况照片的时间标记。")
        }
        writer.add(metadata.assetWriterInput)
        guard writer.startWriting() else {
            throw writer.error ?? BuildError.message("无法创建实况照片视频。")
        }
        writer.startSession(atSourceTime: .zero)
        guard reader.startReading() else {
            throw reader.error ?? BuildError.message("无法读取实况照片视频。")
        }

        let nominalRate = try await videoTrack.load(.nominalFrameRate)
        let frameDuration = CMTime(seconds: 1.0 / max(Double(nominalRate), 1), preferredTimescale: 60_000)
        // The source photo is supplied separately; without a source key-frame timestamp,
        // the middle of the motion clip is the most useful playback anchor.
        let stillTime = CMTimeAdd(videoRange.start, CMTimeMultiplyByFloat64(videoRange.duration, multiplier: 0.5))
        let still = AVMutableMetadataItem()
        still.keySpace = .quickTimeMetadata
        still.key = stillKey as NSString
        still.value = NSNumber(value: Int8(0))
        still.dataType = kCMMetadataBaseDataType_SInt8 as String
        let marker = AVTimedMetadataGroup(items: [still], timeRange: CMTimeRange(
            start: stillTime, duration: CMTimeMinimum(frameDuration, CMTimeMultiplyByFloat64(videoRange.duration, multiplier: 0.5))
        ))
        guard metadata.append(marker) else {
            throw writer.error ?? BuildError.message("无法写入实况照片的时间标记。")
        }
        metadata.assetWriterInput.markAsFinished()

        var lastProgress = Date()
        while channels.contains(where: { !$0.finished }) {
            try Task.checkCancellation()
            guard writer.status == .writing else {
                throw writer.error ?? BuildError.message("实况照片合成已中断。")
            }
            if reader.status == .failed {
                throw reader.error ?? BuildError.message("读取实况片段失败。")
            }
            var advanced = false
            // Interleave every track on one task; writing all video before audio can
            // deadlock the writer's backpressure mechanism.
            for channel in channels where !channel.finished && channel.input.isReadyForMoreMediaData {
                try Task.checkCancellation()
                if let sample = channel.output.copyNextSampleBuffer() {
                    guard channel.input.append(sample) else {
                        throw writer.error ?? BuildError.message("写入实况片段失败。")
                    }
                    channel.samples += 1
                } else {
                    if reader.status == .failed {
                        throw reader.error ?? BuildError.message("实况片段数据不完整。")
                    }
                    channel.input.markAsFinished()
                    channel.finished = true
                }
                advanced = true
            }
            if advanced { lastProgress = Date() }
            else {
                guard Date().timeIntervalSince(lastProgress) < 30 else {
                    throw BuildError.message("实况照片合成超时，请重试。")
                }
                try await Task.sleep(for: .milliseconds(2))
            }
        }
        guard channels.first?.samples ?? 0 > 0 else {
            throw BuildError.message("实况片段不包含可播放的视频帧。")
        }
        try Task.checkCancellation()
        let cancellation = WriterCancellation(writer: writer)
        await withTaskCancellationHandler {
            await writer.finishWriting()
        } onCancel: {
            cancellation.cancel()
        }
        try Task.checkCancellation()
        guard writer.status == .completed else {
            throw writer.error ?? BuildError.message("无法完成实况照片合成。")
        }
        finished = true
    }

    private static func makeMetadataAdaptor() throws -> AVAssetWriterInputMetadataAdaptor {
        let specifications: [[String: Any]] = [[
            kCMMetadataFormatDescriptionMetadataSpecificationKey_Identifier as String: "mdta/\(stillKey)",
            kCMMetadataFormatDescriptionMetadataSpecificationKey_DataType as String: kCMMetadataBaseDataType_SInt8 as String
        ]]
        var description: CMMetadataFormatDescription?
        let status = CMMetadataFormatDescriptionCreateWithMetadataSpecifications(
            allocator: kCFAllocatorDefault, metadataType: kCMMetadataFormatType_Boxed,
            metadataSpecifications: specifications as CFArray, formatDescriptionOut: &description
        )
        guard status == noErr, let description else {
            throw BuildError.message("无法创建 Live Photo 元数据格式。")
        }
        let input = AVAssetWriterInput(mediaType: .metadata, outputSettings: nil, sourceFormatHint: description)
        input.expectsMediaDataInRealTime = false
        return AVAssetWriterInputMetadataAdaptor(assetWriterInput: input)
    }

    /// Photos validates local resources without adding them to the user's library.
    private static func validate(_ files: LivePhotoFiles) async throws {
        let validation = ValidationRequest()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                guard validation.install(continuation) else { return }
                let requestID = PHLivePhoto.request(
                    withResourceFileURLs: [files.photoURL, files.pairedVideoURL],
                    placeholderImage: nil, targetSize: CGSize(width: 512, height: 512), contentMode: .aspectFit
                ) { livePhoto, info in
                    if (info[PHLivePhotoInfoCancelledKey] as? NSNumber)?.boolValue == true {
                        validation.finish(.failure(CancellationError()))
                    } else if let error = info[PHLivePhotoInfoErrorKey] as? Error {
                        validation.finish(.failure(error))
                    } else if (info[PHLivePhotoInfoIsDegradedKey] as? NSNumber)?.boolValue != true {
                        if livePhoto != nil { validation.finish(.success(())) }
                        else { validation.finish(.failure(BuildError.message("系统无法识别这组 Live Photo 文件，请重新下载。"))) }
                    }
                }
                validation.setRequestID(requestID)
                validation.scheduleTimeout()
            }
        } onCancel: {
            validation.finish(.failure(CancellationError()))
        }
    }

    private final class MediaChannel {
        let output: AVAssetReaderTrackOutput
        let input: AVAssetWriterInput
        var finished = false
        var samples = 0
        init(output: AVAssetReaderTrackOutput, input: AVAssetWriterInput) {
            self.output = output
            self.input = input
        }
    }

    // AVAssetWriter explicitly permits cancelling an outstanding finishWriting().
    private struct WriterCancellation: @unchecked Sendable {
        let writer: AVAssetWriter
        func cancel() { writer.cancelWriting() }
    }

    private enum BuildError: LocalizedError {
        case message(String)
        var errorDescription: String? { if case let .message(message) = self { return message }; return nil }
    }

    /// Photos may call its handler repeatedly and from arbitrary queues. A single
    /// locked completion also covers cancellation before request() returns its ID.
    private final class ValidationRequest: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, Error>?
        private var result: Result<Void, Error>?
        private var requestID = PHLivePhotoRequestIDInvalid
        private var timeout: DispatchWorkItem?

        func install(_ continuation: CheckedContinuation<Void, Error>) -> Bool {
            lock.lock()
            if let result {
                lock.unlock()
                continuation.resume(with: result)
                return false
            }
            self.continuation = continuation
            lock.unlock()
            return true
        }

        func setRequestID(_ id: PHLivePhotoRequestID) {
            lock.lock()
            requestID = id
            let isFinished = result != nil
            lock.unlock()
            if isFinished { PHLivePhoto.cancelRequest(withRequestID: id) }
        }

        func scheduleTimeout() {
            let item = DispatchWorkItem { [weak self] in
                self?.finish(.failure(BuildError.message("系统校验 Live Photo 超时，请重试。")))
            }
            lock.lock()
            let isFinished = result != nil
            if !isFinished { timeout = item }
            lock.unlock()
            if !isFinished { DispatchQueue.global().asyncAfter(deadline: .now() + 30, execute: item) }
        }

        func finish(_ result: Result<Void, Error>) {
            lock.lock()
            guard self.result == nil else { lock.unlock(); return }
            self.result = result
            let continuation = self.continuation
            self.continuation = nil
            let id = requestID
            let timeout = self.timeout
            self.timeout = nil
            lock.unlock()
            timeout?.cancel()
            if id != PHLivePhotoRequestIDInvalid { PHLivePhoto.cancelRequest(withRequestID: id) }
            continuation?.resume(with: result)
        }
    }
}
