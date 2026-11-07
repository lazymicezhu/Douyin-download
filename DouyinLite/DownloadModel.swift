import Foundation
import Combine
import Photos

enum PhotoSaveMode: String, CaseIterable, Identifiable {
    case live = "实况照片", still = "仅静态图片", components = "图片＋独立视频"
    var id: String { rawValue }
    var shortTitle: String {
        switch self {
        case .live: return "实况"
        case .still: return "静图"
        case .components: return "图＋视频"
        }
    }
}

struct SharePayload: Identifiable {
    let id = UUID()
    let urls: [URL]
}

@MainActor
final class DownloadModel: ObservableObject {
    @Published var input = ""
    @Published private(set) var video: VideoInfo?
    @Published private(set) var busy = false
    @Published private(set) var canCancel = false
    /// Progress text, only meaningful while `busy`.
    @Published private(set) var status = ""
    /// Short-lived confirmation shown as a toast after an operation completes.
    @Published var notice: String?
    @Published var errorMessage: String?
    @Published var sharePayload: SharePayload?
    @Published private(set) var hasAPIKey = KeyStore.read() != nil
    @Published var qualityID = ""
    @Published var selectedPhotoIDs: Set<Int> = []
    @Published var photoMode: PhotoSaveMode = .live
    @Published var motionQualityIDs: [Int: String] = [:]
    /// Photos-library items this app created and has not cleaned up yet.
    @Published private(set) var savedAssetCount = SavedAssets.load().count
    private let billing: BillingCenter
    private var operation: Task<Void, Never>?
    private let folder = FileManager.default.temporaryDirectory.appendingPathComponent("DouyinLite", isDirectory: true)
    private var lastShareURL: URL?
    private var fileCache: [String: URL] = [:]
    private var liveCache: [String: LivePhotoFiles] = [:]

    var selectedPhotos: [PhotoInfo] { video?.photos.filter { selectedPhotoIDs.contains($0.id) } ?? [] }
    var selectedQuality: VideoQuality? { video?.qualities.first { $0.id == qualityID } }
    var canSave: Bool { video.map { !$0.isPhotoPost || !selectedPhotoIDs.isEmpty } ?? false }
    var hasOriginal: Bool { video?.qualities.contains { $0.id == "original" } ?? false }

    init(billing: BillingCenter) {
        self.billing = billing
        try? FileManager.default.removeItem(at: folder)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    func setAPIKey(_ value: String) throws {
        guard !busy, !billing.isWorking else { throw AppError.message("请等待当前操作完成后更换密钥。") }
        try KeyStore.save(Configuration.validatedKey(value))
        hasAPIKey = true
        billing.credentialsChanged()
    }

    func importConfiguration(_ url: URL) async throws {
        let key = try await ConfigurationFileReader.readKey(from: url)
        try Task.checkCancellation()
        try setAPIKey(key)
    }

    func removeAPIKey() throws {
        guard !busy, !billing.isWorking else { throw AppError.message("请等待当前操作完成后移除密钥。") }
        try KeyStore.remove()
        hasAPIKey = false
        billing.credentialsChanged()
    }

    func resolve(refresh: Bool = false) async {
        guard !busy else { return }
        await perform {
            let shareURL = try DouyinShareLink.extract(from: self.input)
            if !refresh, self.lastShareURL == shareURL, self.video != nil {
                self.notice = "已是当前作品，未重复查询"
                return
            }
            self.status = "正在核对费用…"
            // Parsing is cheap ($0.001) and frequent: skip the confirmation sheet unless the quote is unexpectedly high.
            let data = try await self.billing.perform(APIRequest(title: refresh ? "重新获取作品链接" : "获取作品", path: "/api/v1/douyin/web/fetch_one_video_by_share_url", query: ["share_url": shareURL.absoluteString]),
                                                      autoApproveUpTo: BillingCenter.autoApproveLimit)
            let result = try TikHubResponse.decode(data, status: 200)
            try Task.checkCancellation()
            try? FileManager.default.removeItem(at: self.folder)
            try FileManager.default.createDirectory(at: self.folder, withIntermediateDirectories: true)
            self.fileCache = [:]
            self.liveCache = [:]
            self.video = result
            self.qualityID = result.qualities.first?.id ?? ""
            self.selectedPhotoIDs = Set(result.photos.map(\.id))
            self.motionQualityIDs = Dictionary(uniqueKeysWithValues: result.photos.compactMap { photo in photo.qualities.first.map { (photo.id, $0.id) } })
            self.lastShareURL = shareURL
        }
    }

    func fetchOriginal() async {
        guard !busy, let current = video, !current.isPhotoPost else { return }
        if let original = current.qualities.first(where: { $0.id == "original" }) {
            qualityID = original.id
            return
        }
        await perform {
            self.status = "正在核对费用…"
            let data = try await self.billing.perform(APIRequest(title: "获取原画视频", path: "/api/v1/douyin/web/fetch_video_high_quality_play_url", query: ["aweme_id": current.id]))
            let quality = try TikHubResponse.decodeOriginal(data, status: 200)
            try Task.checkCancellation()
            self.video?.qualities.insert(quality, at: 0)
            self.qualityID = quality.id
            self.notice = "已获取原画"
        }
    }

    /// Downloads (or reuses cached files) and opens the share sheet in one step.
    /// `compatibleCopy` exports the original-quality video with the Photos playback marker.
    func export(compatibleCopy: Bool = false) async {
        guard !busy else { return }
        await perform {
            let assets = try await self.prepareAssets(forPhotoLibrary: compatibleCopy)
            try Task.checkCancellation()
            let urls = assets.flatMap { [$0.photo, $0.video, $0.pairedVideo].compactMap { $0 } }
            guard !urls.isEmpty else { throw AppError.message("没有可导出的文件。") }
            self.sharePayload = SharePayload(urls: urls)
        }
    }

    func saveToPhotos() async {
        guard !busy else { return }
        await perform {
            let authorization = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            try Task.checkCancellation()
            guard authorization == .authorized || authorization == .limited else {
                throw AppError.message("没有添加照片权限。请到系统设置开启，或使用导出文件。")
            }
            let assets = try await self.prepareAssets(forPhotoLibrary: true)
            try Task.checkCancellation()
            self.canCancel = false
            self.status = "正在保存到相册…"
            let created = SavedAssets.Collector()
            try await PHPhotoLibrary.shared().performChanges {
                for asset in assets {
                    if let photo = asset.photo {
                        let creation = PHAssetCreationRequest.forAsset()
                        creation.addResource(with: .photo, fileURL: photo, options: nil)
                        if let paired = asset.pairedVideo { creation.addResource(with: .pairedVideo, fileURL: paired, options: nil) }
                        created.add(creation.placeholderForCreatedAsset?.localIdentifier)
                    }
                    if let video = asset.video {
                        let creation = PHAssetCreationRequest.forAsset()
                        creation.addResource(with: .video, fileURL: video, options: nil)
                        created.add(creation.placeholderForCreatedAsset?.localIdentifier)
                    }
                }
            }
            SavedAssets.append(created.identifiers)
            self.savedAssetCount = SavedAssets.load().count
            self.notice = "已保存到相册"
        }
    }


    /// Deletes only the Photos items this app saved (iOS asks the user to confirm; they go to Recently Deleted).
    func cleanUpSavedPhotos() async {
        guard !busy else { return }
        await perform {
            let identifiers = SavedAssets.load()
            guard !identifiers.isEmpty else { self.notice = "没有需要清理的照片"; return }
            let authorization = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
            guard authorization == .authorized || authorization == .limited else {
                throw AppError.message("清理需要“完全访问”相册权限。请到系统设置开启后重试。")
            }
            self.canCancel = false
            self.status = "正在清理已保存的照片…"
            let found = PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil)
            if found.count > 0 {
                try await PHPhotoLibrary.shared().performChanges {
                    PHAssetChangeRequest.deleteAssets(found)
                }
            }
            // Identifiers not found were already removed by hand; forget them too.
            SavedAssets.remove(identifiers)
            self.savedAssetCount = SavedAssets.load().count
            self.notice = found.count > 0 ? "已清理 \(found.count) 项，可在“最近删除”中恢复" : "照片已不在相册中，记录已清空"
        }
    }

    func cancel() {
        guard operation != nil, canCancel else { return }
        operation?.cancel()
        status = "正在取消…"
    }

    private func perform(_ action: @escaping @MainActor () async throws -> Void) async {
        busy = true
        canCancel = true
        status = "正在处理…"
        errorMessage = nil
        notice = nil
        operation = Task { @MainActor in
            do { try await action() }
            catch is CancellationError { }
            catch let error as URLError where error.code == .cancelled { }
            catch let error as AppError { self.errorMessage = error.localizedDescription }
            catch let error as URLError {
                self.errorMessage = (error.code == .timedOut ? "连接超时" : "网络连接失败") + "，请检查网络后重试。不会自动重新调用接口。"
            }
            catch { self.errorMessage = "处理失败：\(error.localizedDescription)" }
            self.status = ""
            self.canCancel = false
            self.busy = false
            self.operation = nil
        }
        await operation?.value
    }

    private struct LocalAsset {
        var photo: URL? = nil
        var video: URL? = nil
        var pairedVideo: URL? = nil
    }

    private func usable(_ url: URL) -> Bool {
        ((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) > 0
    }

    private func prepareAssets(forPhotoLibrary: Bool = false) async throws -> [LocalAsset] {
        guard let video else { throw AppError.message("请先获取作品。") }
        if !video.isPhotoPost {
            let quality = selectedQuality
            let cacheKey = "video:\(quality?.id ?? "default")"
            let local: URL
            if let cached = fileCache[cacheKey], usable(cached) { local = cached }
            else {
                status = "正在下载视频…"
                local = try await VideoDownloader.download(urls: quality?.urls ?? video.downloadURLs, to: folder)
                fileCache[cacheKey] = local
            }
            if forPhotoLibrary, quality?.id == "original" {
                let compatibleKey = "photos:original"
                let compatible: URL
                if let cached = fileCache[compatibleKey], usable(cached) { compatible = cached }
                else {
                    status = "正在添加原帧率播放标记…"
                    compatible = try await VideoTimingNormalizer.prepareOriginalForPhotos(local, in: folder)
                    fileCache[compatibleKey] = compatible
                }
                return [LocalAsset(video: compatible)]
            }
            return [LocalAsset(video: local)]
        }
        let photos = selectedPhotos
        guard !photos.isEmpty else { throw AppError.message("请至少选择一张图片。") }
        var result: [LocalAsset] = []
        for (index, photo) in photos.enumerated() {
            try Task.checkCancellation()
            status = "正在下载 \(index + 1) / \(photos.count)…"
            let photoKey = "photo:\(photo.id)"
            let still: URL
            if let cached = fileCache[photoKey], usable(cached) { still = cached }
            else {
                still = try await ImageDownloader.download(photo, to: folder)
                fileCache[photoKey] = still
            }
            if photoMode == .still || photo.motionURLs.isEmpty {
                result.append(LocalAsset(photo: still))
                continue
            }
            let quality = photo.qualities.first { $0.id == motionQualityIDs[photo.id] } ?? photo.qualities.first
            let motionKey = "motion:\(photo.id):\(quality?.id ?? "default")"
            let motion: URL
            if let cached = fileCache[motionKey], usable(cached) { motion = cached }
            else {
                motion = try await VideoDownloader.download(urls: quality?.urls ?? photo.motionURLs, to: folder)
                fileCache[motionKey] = motion
            }
            if photoMode == .components {
                result.append(LocalAsset(photo: still, video: motion))
            } else {
                status = "正在合成实况 \(index + 1) / \(photos.count)…"
                let pair: LivePhotoFiles
                if let cached = liveCache[motionKey], usable(cached.photoURL), usable(cached.pairedVideoURL) { pair = cached }
                else {
                    do { pair = try await LivePhotoBuilder.build(photo: still, video: motion, in: folder) }
                    catch is CancellationError { throw CancellationError() }
                    catch { throw AppError.message("第 \(photo.id + 1) 张实况合成失败。可改用“图＋视频”方式保存。") }
                    liveCache[motionKey] = pair
                }
                result.append(LocalAsset(photo: pair.photoURL, pairedVideo: pair.pairedVideoURL))
            }
        }
        return result
    }
}

/// Local identifiers of Photos items saved by this app, so cleanup never touches anything else.
enum SavedAssets {
    private static let key = "savedAssetIdentifiers"

    static func load() -> [String] { UserDefaults.standard.stringArray(forKey: key) ?? [] }

    static func append(_ identifiers: [String]) {
        guard !identifiers.isEmpty else { return }
        var current = load()
        for id in identifiers where !current.contains(id) { current.append(id) }
        UserDefaults.standard.set(current, forKey: key)
    }

    static func remove(_ identifiers: [String]) {
        let drop = Set(identifiers)
        UserDefaults.standard.set(load().filter { !drop.contains($0) }, forKey: key)
    }

    /// Collects placeholder identifiers inside a Photos change block (which runs off the main actor).
    final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String] = []
        func add(_ id: String?) { guard let id else { return }; lock.lock(); values.append(id); lock.unlock() }
        var identifiers: [String] { lock.lock(); defer { lock.unlock() }; return values }
    }
}
