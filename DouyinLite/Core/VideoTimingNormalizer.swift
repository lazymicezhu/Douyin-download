import Foundation
import AVFoundation
import CoreMedia

/// Declares the original video's intended playback speed without changing any
/// compressed audio/video sample or its timestamp. Only used for Photos copies.
enum VideoTimingNormalizer {
    private static let intentKey = "com.apple.quicktime.full-frame-rate-playback-intent"

    static func prepareOriginalForPhotos(_ source: URL, in folder: URL) async throws -> URL {
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appendingPathComponent("原画-全帧率-\(UUID().uuidString.prefix(8)).mov")
        var completed = false
        defer {
            if !completed { try? FileManager.default.removeItem(at: destination) }
        }

        let asset = AVURLAsset(url: source)
        let sourceDuration = try await asset.load(.duration)
        guard sourceDuration.isNumeric, sourceDuration.seconds > 0 else {
            throw AppError.message("原画时长无效，无法制作相册副本。原始文件仍可导出。")
        }
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard !videoTracks.isEmpty else {
            throw AppError.message("原画没有视频轨道。原始文件仍可导出。")
        }
        let sourceVideoProperties = try await properties(of: videoTracks)
        let reader = try AVAssetReader(asset: asset)
        let writer = try AVAssetWriter(outputURL: destination, fileType: .mov)
        var finishedWriting = false
        defer {
            if !finishedWriting {
                reader.cancelReading()
                writer.cancelWriting()
            }
        }

        var channels: [Channel] = []
        // Carry only the actual audio/video tracks. In particular, do not copy
        // Live Photo still-image markers or camera adjustment metadata tracks.
        for track in videoTracks + audioTracks {
            try Task.checkCancellation()
            guard let format = try await track.load(.formatDescriptions).first else {
                throw AppError.message("无法识别原画编码，原始文件仍可导出。")
            }
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            output.alwaysCopiesSampleData = false
            let input = AVAssetWriterInput(mediaType: track.mediaType, outputSettings: nil, sourceFormatHint: format)
            input.expectsMediaDataInRealTime = false
            input.marksOutputTrackAsEnabled = try await track.load(.isEnabled)
            if track.mediaType == .video {
                let timeScale = try await track.load(.naturalTimeScale)
                if timeScale > 0 { input.mediaTimeScale = timeScale }
                input.naturalSize = try await track.load(.naturalSize)
                input.transform = try await track.load(.preferredTransform)
            } else if track.mediaType == .audio {
                input.preferredVolume = try await track.load(.preferredVolume)
            }
            input.metadata = try await track.load(.metadata).filter(keepMetadata)
            guard reader.canAdd(output), writer.canAdd(input) else {
                throw AppError.message("该原画编码暂不支持制作无损相册副本，原始文件仍可导出。")
            }
            reader.add(output)
            writer.add(input)
            channels.append(Channel(output: output, input: input))
        }

        let intent = AVMutableMetadataItem()
        if #available(iOS 18.0, macOS 15.0, *) {
            intent.identifier = .quickTimeMetadataFullFrameRatePlaybackIntent
        } else {
            // The key can be written on iOS 17, but interpreting this hint is a
            // player capability introduced in iOS 18; older Photos may ignore it.
            intent.keySpace = .quickTimeMetadata
            intent.key = intentKey as NSString
        }
        intent.dataType = kCMMetadataBaseDataType_UInt8 as String
        intent.value = NSNumber(value: UInt8(1))
        writer.metadata = try await asset.load(.metadata).filter(keepMetadata) + [intent]

        guard writer.startWriting() else {
            throw writer.error ?? AppError.message("无法创建相册副本，原始文件仍可导出。")
        }
        // Zero is the asset's timeline origin, not the first video/audio sample.
        // Preserve leading offsets and A/V alignment; never rescale sample times.
        writer.startSession(atSourceTime: .zero)
        guard reader.startReading() else {
            throw reader.error ?? AppError.message("无法读取原画，原始文件仍可导出。")
        }

        var lastProgress = Date()
        while channels.contains(where: { !$0.finished }) {
            try Task.checkCancellation()
            guard writer.status == .writing else {
                throw writer.error ?? AppError.message("制作相册副本已中断，原始文件仍可导出。")
            }
            if reader.status == .failed {
                throw reader.error ?? AppError.message("原画数据读取失败，原始文件仍可导出。")
            }
            var progressed = false
            // Interleave the tracks so one cannot block while waiting for another
            // to drain the writer's backpressure queue.
            for channel in channels where !channel.finished && channel.input.isReadyForMoreMediaData {
                try Task.checkCancellation()
                if let sample = channel.output.copyNextSampleBuffer() {
                    guard channel.input.append(sample) else {
                        throw writer.error ?? AppError.message("相册副本写入失败，原始文件仍可导出。")
                    }
                    channel.samples += 1
                } else {
                    if reader.status == .failed {
                        throw reader.error ?? AppError.message("原画数据不完整，原始文件仍可导出。")
                    }
                    channel.input.markAsFinished()
                    channel.finished = true
                }
                progressed = true
            }
            if progressed { lastProgress = Date() }
            else {
                guard Date().timeIntervalSince(lastProgress) < 30 else {
                    throw AppError.message("制作相册副本超时，原始文件仍可导出。")
                }
                try await Task.sleep(for: .milliseconds(2))
            }
        }
        guard channels.prefix(videoTracks.count).allSatisfy({ $0.samples > 0 }) else {
            throw AppError.message("原画没有可写入的视频帧，原始文件仍可导出。")
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
            throw writer.error ?? AppError.message("相册副本未完成，原始文件仍可导出。")
        }
        finishedWriting = true

        try await validate(destination, sourceDuration: sourceDuration,
                           sourceVideoProperties: sourceVideoProperties, audioCount: audioTracks.count)
        try Task.checkCancellation()
        completed = true
        return destination
    }

    private static func keepMetadata(_ item: AVMetadataItem) -> Bool {
        let names = [item.identifier?.rawValue ?? "", item.key as? String ?? ""].map { $0.lowercased() }
        return !names.contains { name in
            name.contains(intentKey) || name.contains("com.apple.quicktime.content.identifier") ||
            name.contains("still-image-time") || name.contains("live-photo") || name.contains("livephoto")
        }
    }

    private struct VideoProperties {
        let frameRate: Float
        let size: CGSize
        let transform: CGAffineTransform
        let timeRange: CMTimeRange
    }

    private static func properties(of tracks: [AVAssetTrack]) async throws -> [VideoProperties] {
        var result: [VideoProperties] = []
        for track in tracks {
            result.append(VideoProperties(frameRate: try await track.load(.nominalFrameRate),
                                          size: try await track.load(.naturalSize),
                                          transform: try await track.load(.preferredTransform),
                                          timeRange: try await track.load(.timeRange)))
        }
        return result
    }

    private static func validate(_ url: URL, sourceDuration: CMTime,
                                 sourceVideoProperties: [VideoProperties], audioCount: Int) async throws {
        let result = AVURLAsset(url: url)
        let duration = try await result.load(.duration)
        let videos = try await result.loadTracks(withMediaType: .video)
        let audio = try await result.loadTracks(withMediaType: .audio)
        guard duration.isNumeric, abs(duration.seconds - sourceDuration.seconds) <= 0.1,
              videos.count == sourceVideoProperties.count, audio.count == audioCount else {
            throw AppError.message("相册副本的时长或音视频轨道校验失败，原始文件仍可导出。")
        }
        let resultProperties = try await properties(of: videos)
        for (before, after) in zip(sourceVideoProperties, resultProperties) {
            let rateTolerance = max(0.1, abs(before.frameRate) * 0.005)
            guard before.size == after.size, sameTransform(before.transform, after.transform),
                  before.frameRate <= 0 || abs(before.frameRate - after.frameRate) <= rateTolerance,
                  before.timeRange.start.isNumeric, after.timeRange.start.isNumeric,
                  abs(before.timeRange.start.seconds - after.timeRange.start.seconds) <= 0.05,
                  abs(before.timeRange.duration.seconds - after.timeRange.duration.seconds) <= 0.1 else {
                throw AppError.message("相册副本未通过原尺寸、帧率或时间轴校验，原始文件仍可导出。")
            }
        }
        let metadata = try await result.load(.metadata)
        var foundIntent = false
        for item in metadata {
            let names = [item.identifier?.rawValue ?? "", item.key as? String ?? ""]
            if names.contains(where: { $0.contains(intentKey) }) {
                let value = try await item.load(.numberValue)
                if value?.uint8Value == 1, item.dataType == kCMMetadataBaseDataType_UInt8 as String {
                    foundIntent = true
                } else {
                    throw AppError.message("相册副本的全帧率播放标记无效，原始文件仍可导出。")
                }
            }
        }
        guard foundIntent else {
            throw AppError.message("相册副本缺少全帧率播放标记，原始文件仍可导出。")
        }
    }

    private static func sameTransform(_ lhs: CGAffineTransform, _ rhs: CGAffineTransform) -> Bool {
        zip([lhs.a, lhs.b, lhs.c, lhs.d, lhs.tx, lhs.ty], [rhs.a, rhs.b, rhs.c, rhs.d, rhs.tx, rhs.ty])
            .allSatisfy { pair in abs(pair.0 - pair.1) <= 0.0001 }
    }

    private final class Channel {
        let output: AVAssetReaderTrackOutput
        let input: AVAssetWriterInput
        var finished = false
        var samples = 0
        init(output: AVAssetReaderTrackOutput, input: AVAssetWriterInput) {
            self.output = output
            self.input = input
        }
    }

    private struct WriterCancellation: @unchecked Sendable {
        let writer: AVAssetWriter
        func cancel() { writer.cancelWriting() }
    }
}
