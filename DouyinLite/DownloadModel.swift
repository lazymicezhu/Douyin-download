import Foundation
import Combine
import Photos

enum PhotoSaveMode: String, CaseIterable, Identifiable {
    case live = "实况照片", still = "仅静态图片", components = "图片＋独立视频"
    var id: String { rawValue }
}

@MainActor
final class DownloadModel: ObservableObject {
    @Published var input = ""
    @Published private(set) var video: VideoInfo?
    @Published private(set) var busy = false
    @Published private(set) var canCancel = false
    @Published private(set) var status = "粘贴分享链接，获取视频、图文或实况。"
    @Published var errorMessage: String?
    @Published private(set) var exportFiles: [URL] = []
    @Published private(set) var compatibleVideoFile: URL?
    @Published private(set) var hasAPIKey = KeyStore.read() != nil
    @Published var qualityID = "" { didSet { exportFiles = [] } }
    @Published var selectedPhotoIDs: Set<Int> = [] { didSet { exportFiles = [] } }
    @Published var photoMode: PhotoSaveMode = .live { didSet { exportFiles = [] } }
    @Published var motionQualityIDs: [Int: String] = [:] { didSet { exportFiles = [] } }
    private let billing: BillingCenter
    private var operation: Task<Void, Never>?
    private let folder = FileManager.default.temporaryDirectory.appendingPathComponent("DouyinLite", isDirectory: true)
    private var lastShareURL: URL?
    private var fileCache: [String: URL] = [:]
    private var liveCache: [String: LivePhotoFiles] = [:]

    var selectedPhotos: [PhotoInfo] { video?.photos.filter { selectedPhotoIDs.contains($0.id) } ?? [] }
    var selectedQuality: VideoQuality? { video?.qualities.first { $0.id == qualityID } }
    var canSave: Bool { video.map { !$0.isPhotoPost || !selectedPhotoIDs.isEmpty } ?? false }

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
        status = "密钥已移除。"
    }

    func resolve(refresh: Bool = false) async {
        guard !busy else { return }
        await perform {
            let shareURL = try DouyinShareLink.extract(from: self.input)
            if !refresh, self.lastShareURL == shareURL, self.video != nil {
                self.status = "已使用本次会话中的结果，没有再次调用接口。"
                return
            }
            self.status = "正在核对解析费用…"
            let data = try await self.billing.perform(APIRequest(title: refresh ? "重新获取作品链接" : "获取作品", path: "/api/v1/douyin/web/fetch_one_video_by_share_url", query: ["share_url": shareURL.absoluteString]))
            let result = try TikHubResponse.decode(data, status: 200)
            try Task.checkCancellation()
            try? FileManager.default.removeItem(at: self.folder)
            try FileManager.default.createDirectory(at: self.folder, withIntermediateDirectories: true)
            self.fileCache = [:]
            self.liveCache = [:]
            self.exportFiles = []
            self.compatibleVideoFile = nil
            self.video = result
            self.qualityID = result.qualities.first?.id ?? ""
            self.selectedPhotoIDs = Set(result.photos.map(\.id))
            self.motionQualityIDs = Dictionary(uniqueKeysWithValues: result.photos.compactMap { photo in photo.qualities.first.map { (photo.id, $0.id) } })
            self.lastShareURL = shareURL
            self.status = result.isPhotoPost ? "已获取 \(result.photos.count) 张图片，其中 \(result.motionCount) 张含实况视频。" : "视频已就绪，默认选择最高可用画质。"
        }
    }

    func fetchOriginal() async {
        guard !busy, let current = video, !current.isPhotoPost else { return }
        if let original = current.qualities.first(where: { $0.id == "original" }) {
            qualityID = original.id
            status = "已选择已获取的原画，没有重复查询。"
            return
        }
        await perform {
            self.status = "正在核对原画费用…"
            let data = try await self.billing.perform(APIRequest(title: "获取原画视频", path: "/api/v1/douyin/web/fetch_video_high_quality_play_url", query: ["aweme_id": current.id]))
            let quality = try TikHubResponse.decodeOriginal(data, status: 200)
            try Task.checkCancellation()
            self.video?.qualities.insert(quality, at: 0)
            self.qualityID = quality.id
            self.status = "原画链接已获取，可保存或导出。实际画质取决于上传素材。"
        }
    }

    func download() async {
        guard !busy else { return }
        await perform {
            let assets = try await self.prepareAssets()
            self.exportFiles = assets.flatMap { [$0.photo, $0.video, $0.pairedVideo].compactMap { $0 } }
            self.status = self.photoMode == .live && assets.contains(where: { $0.pairedVideo != nil })
                ? "实况已合成。导出为配对的图片和 MOV；要在 iPhone 中显示为实况，请用“保存到相册”。"
                : "下载完成，可以导出到文件或分享。"
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
            try await PHPhotoLibrary.shared().performChanges {
                for asset in assets {
                    if let photo = asset.photo {
                        let creation = PHAssetCreationRequest.forAsset()
                        creation.addResource(with: .photo, fileURL: photo, options: nil)
                        if let paired = asset.pairedVideo { creation.addResource(with: .pairedVideo, fileURL: paired, options: nil) }
                    }
                    if let video = asset.video {
                        let creation = PHAssetCreationRequest.forAsset()
                        creation.addResource(with: .video, fileURL: video, options: nil)
                    }
                }
            }
            self.exportFiles = assets.flatMap { [$0.photo, $0.video, $0.pairedVideo].compactMap { $0 } }
            if self.selectedQuality?.id == "original", let original = self.fileCache["video:original"] {
                self.exportFiles = [original]
            }
            self.status = "已保存到相册。"
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
        errorMessage = nil
        operation = Task { @MainActor in
            do { try await action() }
            catch is CancellationError { self.status = "已取消。" }
            catch let error as URLError where error.code == .cancelled { self.status = "已取消。" }
            catch let error as AppError { self.errorMessage = error.localizedDescription; self.status = "操作未完成。" }
            catch let error as URLError {
                self.errorMessage = error.code == .timedOut ? "连接超时，请检查网络后重试。" : "网络连接失败，请检查网络后重试。"
                self.status = "操作未完成；不会自动重新调用接口。"
            }
            catch { self.errorMessage = "处理失败：\(error.localizedDescription)"; self.status = "操作未完成。" }
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
                status = "正在下载所选画质…"
                local = try await VideoDownloader.download(urls: quality?.urls ?? video.downloadURLs, to: folder)
                fileCache[cacheKey] = local
            }
            if forPhotoLibrary, quality?.id == "original" {
                let compatibleKey = "photos:original"
                let compatible: URL
                if let cached = fileCache[compatibleKey], usable(cached) { compatible = cached }
                else {
                    status = "正在为相册设置原帧率播放标记，不改变画质…"
                    compatible = try await VideoTimingNormalizer.prepareOriginalForPhotos(local, in: folder)
                    fileCache[compatibleKey] = compatible
                }
                compatibleVideoFile = compatible
                return [LocalAsset(video: compatible)]
            }
            return [LocalAsset(video: local)]
        }
        let photos = selectedPhotos
        guard !photos.isEmpty else { throw AppError.message("请至少选择一张图片。") }
        var result: [LocalAsset] = []
        for (index, photo) in photos.enumerated() {
            try Task.checkCancellation()
            status = "正在处理第 \(index + 1) / \(photos.count) 张图片…"
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
                status = "正在合成第 \(index + 1) 张实况照片…"
                let pair: LivePhotoFiles
                if let cached = liveCache[motionKey], usable(cached.photoURL), usable(cached.pairedVideoURL) { pair = cached }
                else {
                    do { pair = try await LivePhotoBuilder.build(photo: still, video: motion, in: folder) }
                    catch is CancellationError { throw CancellationError() }
                    catch { throw AppError.message("第 \(photo.id + 1) 张实况合成失败。可选择“图片＋独立视频”保留完整素材后再次保存。") }
                    liveCache[motionKey] = pair
                }
                result.append(LocalAsset(photo: pair.photoURL, pairedVideo: pair.pairedVideoURL))
            }
        }
        return result
    }
}
