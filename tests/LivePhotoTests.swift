// Standalone macOS integration test. No network, credentials, or Photos-library writes.
// xcrun swiftc DouyinLite/Core/LivePhotoBuilder.swift tests/LivePhotoTests.swift \
//   -module-cache-path /tmp/douyin-live-module-cache -o /tmp/douyin-live-tests
// /tmp/douyin-live-tests [existing-image existing-video]
import Foundation
import AVFoundation
import AppKit
import ImageIO
import UniformTypeIdentifiers
import CryptoKit

@main
struct LivePhotoTests {
    enum Failure: LocalizedError {
        case check(String)
        var errorDescription: String? { if case let .check(message) = self { return message }; return nil }
    }

    static func check(_ name: String, _ condition: Bool) throws {
        guard condition else { throw Failure.check(name) }
        print("PASS: \(name)")
    }

    static func main() async throws {
        setbuf(stdout, nil)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LivePhotoTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let photo: URL
        let video: URL
        if CommandLine.arguments.count == 3 {
            photo = URL(fileURLWithPath: CommandLine.arguments[1])
            video = URL(fileURLWithPath: CommandLine.arguments[2])
        } else {
            print("Creating local synthetic photo/video/audio fixture")
            (photo, video) = try await makeFixture(in: root)
        }
        print("Building and validating Live Photo")
        let folder = root.appendingPathComponent("Output")
        let files = try await LivePhotoBuilder.build(photo: photo, video: video, in: folder)
        try check("PHLivePhoto.request accepted the generated pair", FileManager.default.fileExists(atPath: files.pairedVideoURL.path))

        let imageSource = CGImageSourceCreateWithURL(files.photoURL as CFURL, nil)!
        let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil)! as NSDictionary
        let maker = properties[kCGImagePropertyMakerAppleDictionary] as? [String: Any]
        let identifier = maker?["17"] as? String
        let pairedAsset = AVURLAsset(url: files.pairedVideoURL)
        let content = try await pairedAsset.load(.metadata)
        let contentIdentifier = content.first { $0.identifier == .quickTimeMetadataContentIdentifier }
        let movieID = try await contentIdentifier?.load(.stringValue)
        try check("JPEG Apple Maker 17 matches MOV content.identifier", identifier != nil && identifier == movieID)

        let sourceImage = CGImageSourceCreateWithURL(photo as CFURL, nil)!
        let originalProperties = CGImageSourceCopyPropertiesAtIndex(sourceImage, 0, nil)! as NSDictionary
        try check("image dimensions and EXIF orientation preserved",
                  (properties[kCGImagePropertyPixelWidth] as? NSNumber) == (originalProperties[kCGImagePropertyPixelWidth] as? NSNumber)
                  && (properties[kCGImagePropertyPixelHeight] as? NSNumber) == (originalProperties[kCGImagePropertyPixelHeight] as? NSNumber)
                  && (properties[kCGImagePropertyOrientation] as? NSNumber ?? 1) == (originalProperties[kCGImagePropertyOrientation] as? NSNumber ?? 1))

        let sourceAsset = AVURLAsset(url: video)
        let sourceVideo = try await sourceAsset.loadTracks(withMediaType: .video)[0]
        let pairedVideo = try await pairedAsset.loadTracks(withMediaType: .video)[0]
        let sourceTransform = try await sourceVideo.load(.preferredTransform)
        let pairedTransform = try await pairedVideo.load(.preferredTransform)
        try check("video orientation transform preserved", sourceTransform == pairedTransform)
        let originalVideoHash = try await mediaHash(asset: sourceAsset, track: sourceVideo)
        let pairedVideoHash = try await mediaHash(asset: pairedAsset, track: pairedVideo)
        try check("every compressed video sample retained without re-encoding", originalVideoHash == pairedVideoHash)
        let sourceAudio = try await sourceAsset.loadTracks(withMediaType: .audio)
        let pairedAudio = try await pairedAsset.loadTracks(withMediaType: .audio)
        try check("all audio tracks retained", sourceAudio.count == pairedAudio.count)
        for (index, track) in sourceAudio.enumerated() {
            let originalHash = try await mediaHash(asset: sourceAsset, track: track)
            let pairedHash = try await mediaHash(asset: pairedAsset, track: pairedAudio[index])
            try check("audio track \(index + 1) retained without re-encoding", originalHash == pairedHash)
        }
        let metadataTracks = try await pairedAsset.loadTracks(withMediaType: .metadata)
        try check("MOV has a separate timed metadata track", metadataTracks.count == 1)
        let reader = try AVAssetReader(asset: pairedAsset)
        let output = AVAssetReaderTrackOutput(track: metadataTracks[0], outputSettings: nil)
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? Failure.check("cannot read metadata track") }
        var stillGroup: AVTimedMetadataGroup?
        while let sample = output.copyNextSampleBuffer() {
            if let group = AVTimedMetadataGroup(sampleBuffer: sample),
               group.items.contains(where: { $0.key as? String == "com.apple.quicktime.still-image-time" }) {
                stillGroup = group
                break
            }
        }
        guard let group = stillGroup, let marker = group.items.first else {
            throw Failure.check("cannot read still-image-time marker")
        }
        let duration = try await pairedAsset.load(.duration)
        let markerValue = try await marker.load(.value) as? NSNumber
        try check("still-image-time is an int8 zero at a valid video time",
                  marker.key as? String == "com.apple.quicktime.still-image-time"
                  && marker.dataType == kCMMetadataBaseDataType_SInt8 as String
                  && markerValue?.intValue == 0
                  && group.timeRange.start.seconds >= 0 && group.timeRange.start.seconds < duration.seconds)
        reader.cancelReading()

        let before = try Set(FileManager.default.contentsOfDirectory(atPath: folder.path))
        do {
            _ = try await LivePhotoBuilder.build(photo: photo, video: photo, in: folder)
            throw Failure.check("invalid video unexpectedly succeeded")
        } catch is Failure { throw Failure.check("invalid video unexpectedly succeeded") }
        catch { }
        try check("failure removes only its partial outputs", try Set(FileManager.default.contentsOfDirectory(atPath: folder.path)) == before)

        let task = Task { try await LivePhotoBuilder.build(photo: photo, video: video, in: folder) }
        task.cancel()
        do {
            _ = try await task.value
            throw Failure.check("cancelled build unexpectedly succeeded")
        } catch is CancellationError { }
        try check("cancelled build leaves no output", try Set(FileManager.default.contentsOfDirectory(atPath: folder.path)) == before)
        try check("original source files retained", FileManager.default.fileExists(atPath: photo.path) && FileManager.default.fileExists(atPath: video.path))
        print("Live Photo integration checks passed.")
    }

    static func mediaHash(asset: AVAsset, track: AVAssetTrack) async throws -> String {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? Failure.check("cannot read test media") }
        var hasher = SHA256()
        while let sample = output.copyNextSampleBuffer() {
            // Container edit lists may expose empty media samples with no payload.
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            var bytes = Data(count: CMBlockBufferGetDataLength(block))
            let status = bytes.withUnsafeMutableBytes { pointer in
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: pointer.count, destination: pointer.baseAddress!)
            }
            guard status == noErr else { throw Failure.check("cannot inspect sample") }
            hasher.update(data: bytes)
        }
        guard reader.status == .completed else { throw reader.error ?? Failure.check("incomplete test media") }
        return hasher.finalize().description
    }

    static func makeFixture(in root: URL) async throws -> (URL, URL) {
        let photo = root.appendingPathComponent("source.png")
        let context = CGContext(data: nil, width: 240, height: 320, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 240, height: 320))
        let destination = CGImageDestinationCreateWithURL(photo as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        guard CGImageDestinationFinalize(destination) else { throw Failure.check("fixture image") }

        let silentVideo = root.appendingPathComponent("silent.mp4")
        let writer = try AVAssetWriter(outputURL: silentVideo, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 320, AVVideoHeightKey: 240
        ])
        input.transform = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 240, ty: 0)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 320, kCVPixelBufferHeightKey as String: 240
        ])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? Failure.check("fixture writer") }
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<90 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
            var buffer: CVPixelBuffer?
            guard CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer) == kCVReturnSuccess,
                  let buffer else { throw Failure.check("fixture pixel buffer") }
            CVPixelBufferLockBaseAddress(buffer, [])
            let pointer = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
            let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
            for y in 0..<240 {
                for x in 0..<320 {
                    let offset = y * bytesPerRow + x * 4
                    pointer[offset] = UInt8((x + frame * 2) % 256)
                    pointer[offset + 1] = UInt8(y % 256)
                    pointer[offset + 2] = UInt8(frame * 2)
                    pointer[offset + 3] = 255
                }
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            guard adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: 30)) else {
                throw writer.error ?? Failure.check("fixture frame")
            }
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? Failure.check("fixture finish") }
        print("Synthetic H.264 video encoded")

        // A generated three-second 440Hz WAV becomes an AAC track during MP4 export.
        let audio = root.appendingPathComponent("tone.wav")
        var wave = Data()
        func text(_ value: String) { wave.append(Data(value.utf8)) }
        func word<T: FixedWidthInteger>(_ value: T) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { wave.append(contentsOf: $0) }
        }
        let sampleCount: UInt32 = 48_000 * 3
        text("RIFF"); word(UInt32(36) + sampleCount * 2); text("WAVEfmt ")
        word(UInt32(16)); word(UInt16(1)); word(UInt16(1)); word(UInt32(48_000))
        word(UInt32(96_000)); word(UInt16(2)); word(UInt16(16)); text("data"); word(sampleCount * 2)
        for index in 0..<sampleCount {
            word(Int16(sin(Double(index) / 48_000 * 440 * 2 * .pi) * 5_000))
        }
        try wave.write(to: audio)
        let composition = AVMutableComposition()
        let source = AVURLAsset(url: silentVideo)
        let sourceTrack = try await source.loadTracks(withMediaType: .video)[0]
        let composedVideo = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!
        try composedVideo.insertTimeRange(CMTimeRange(start: .zero, duration: CMTime(seconds: 3, preferredTimescale: 600)), of: sourceTrack, at: .zero)
        composedVideo.preferredTransform = try await sourceTrack.load(.preferredTransform)
        let audioAsset = AVURLAsset(url: audio)
        let sourceAudio = try await audioAsset.loadTracks(withMediaType: .audio)[0]
        let composedAudio = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)!
        try composedAudio.insertTimeRange(CMTimeRange(start: .zero, duration: CMTime(seconds: 3, preferredTimescale: 600)), of: sourceAudio, at: .zero)
        let video = root.appendingPathComponent("source.mp4")
        let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality)!
        print("Exporting synthetic video with audio")
        try await exporter.export(to: video, as: .mp4)
        return (photo, video)
    }
}
