import SwiftUI
import UIKit

@MainActor
struct DownloadView: View {
    @ObservedObject var model: DownloadModel
    @ObservedObject var billing: BillingCenter
    let openSettings: () -> Void
    let openAccount: () -> Void
    @FocusState private var inputIsFocused: Bool

    private var trimmedInput: String { model.input.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var locked: Bool { model.busy || billing.isWorking }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header
                    if model.hasAPIKey { input } else { onboarding }
                    if model.busy {
                        StatusBanner(kind: .progress, text: model.status, cancel: model.canCancel ? { model.cancel() } : nil)
                    }
                    if let error = model.errorMessage {
                        StatusBanner(kind: .error, text: error)
                    }
                    if let video = model.video {
                        Divider().overlay(Theme.hairline)
                        if video.isPhotoPost { photoResult(video) } else { videoResult(video) }
                    }
                }
                .padding(.horizontal, Theme.gutter)
                .padding(.bottom, 24)
                .frame(maxWidth: 640)
                .frame(maxWidth: .infinity)
                .animation(.snappy, value: model.busy)
                .animation(.snappy, value: model.errorMessage)
                .animation(.snappy, value: model.video?.id)
            }
            .scrollDismissesKeyboard(.interactively)
            .toolbar(.hidden, for: .navigationBar)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if let video = model.video { actionBar(video) }
            }
            .toast($model.notice)
            .sheet(item: $model.sharePayload) { payload in
                ActivityView(items: payload.urls).presentationDetents([.medium, .large]).ignoresSafeArea()
            }
        }
    }

    // MARK: Header & input

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("抖取").font(.largeTitle.weight(.bold))
            Spacer()
            if model.hasAPIKey {
                Button(action: openAccount) {
                    HStack(spacing: 3) {
                        if billing.accountError != nil { Image(systemName: "exclamationmark.circle") }
                        Text(billing.account.map { Money.usd($0.balance) } ?? "余额")
                            .monospacedDigit()
                        Image(systemName: "chevron.right").font(.caption2.weight(.bold))
                    }
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(billing.accountError == nil ? Color.secondary : Color.orange)
                }
                .accessibilityLabel(billing.account.map { "余额 \(Money.usd($0.balance))" } ?? "账户")
            }
        }
        .padding(.top, 12)
    }

    private var onboarding: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 10) {
                Text("连接 TikHub").font(.title2.weight(.bold))
                Text("导入配置文件或粘贴 API Key 后，即可解析抖音视频、图文与实况。")
                    .font(.body).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button("开始配置", action: openSettings).buttonStyle(.primary)
        }
        .padding(.top, 32)
    }

    private var input: some View {
        VStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 12) {
                TextField("粘贴抖音分享链接或整段文案", text: $model.input, axis: .vertical)
                    .lineLimit(3...6)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    .focused($inputIsFocused)
                    .disabled(model.busy)
                HStack(spacing: 8) {
                    Spacer()
                    if !model.input.isEmpty {
                        Button { model.input = "" } label: {
                            Text("清空").font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
                                .padding(.horizontal, 12).frame(height: 34)
                        }
                        .disabled(model.busy)
                    }
                    PasteButton(payloadType: String.self) { values in
                        model.input = values.joined(separator: "\n")
                        // A recognizable link resolves immediately; parsing is auto-approved at normal prices.
                        if (try? DouyinShareLink.extract(from: model.input)) != nil { resolve() }
                    }
                    .labelStyle(.titleAndIcon)
                    .buttonBorderShape(.capsule)
                    .tint(Color(uiColor: .systemGray))
                    .disabled(locked)
                }
            }
            .padding(16)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))

            if model.video == nil || !trimmedInput.isEmpty {
                Button("解析", action: resolve)
                    .buttonStyle(.primary)
                    .disabled(locked || trimmedInput.isEmpty)
            }
            if model.video == nil && !model.busy {
                Text("支持视频、图文与实况 · 粘贴即解析，每次约 $0.001")
                    .font(.footnote).foregroundStyle(.tertiary)
            }
        }
    }

    private func resolve() {
        inputIsFocused = false
        Task { await model.resolve() }
    }

    // MARK: Results

    private func summary(_ video: VideoInfo, thumbnail: URL?) -> some View {
        HStack(alignment: .top, spacing: 14) {
            RemoteImage(url: thumbnail)
                .frame(width: 78, height: 104)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(video.title.isEmpty ? "抖音作品" : video.title)
                    .font(.body.weight(.semibold))
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                if !video.author.isEmpty {
                    Text("@\(video.author)").font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
                Text(meta(video)).font(.caption).foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Menu {
                Button("复制文案", systemImage: "doc.on.doc") { copy(video.title, notice: "已复制文案") }
                Button("复制作品 ID", systemImage: "number") { copy(video.id, notice: "已复制作品 ID") }
                Divider()
                Button("重新获取链接（需付费）", systemImage: "arrow.clockwise") {
                    Task { await model.resolve(refresh: true) }
                }
                .disabled(locked)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.primary)
                    .frame(width: 34, height: 34)
                    .background(Theme.surface, in: Circle())
            }
            .accessibilityLabel("更多")
        }
    }

    private func meta(_ video: VideoInfo) -> String {
        if video.isPhotoPost {
            return "图文 · \(video.photos.count) 张" + (video.motionCount > 0 ? " · \(video.motionCount) 张实况" : "")
        }
        guard let seconds = video.durationSeconds, seconds > 0 else { return "视频" }
        return "视频 · " + Duration.seconds(seconds).formatted(.time(pattern: .minuteSecond))
    }

    private func videoResult(_ video: VideoInfo) -> some View {
        VStack(alignment: .leading, spacing: 24) {
            summary(video, thumbnail: video.coverURL)
            VStack(alignment: .leading, spacing: 10) {
                Text("画质").sectionLabel()
                VStack(spacing: 0) {
                    ForEach(Array(video.qualities.enumerated()), id: \.element.id) { index, quality in
                        if index > 0 { Divider().padding(.leading, 16) }
                        qualityRow(quality)
                    }
                    if !model.hasOriginal {
                        if !video.qualities.isEmpty { Divider().padding(.leading, 16) }
                        originalRow
                    }
                }
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
                .disabled(model.busy)
                if model.selectedQuality?.id == "original" {
                    Group {
                        if #available(iOS 18, *) {
                            Text("保存到相册时自动添加原帧率播放标记，不重新压缩。")
                        } else {
                            Text("保存到相册时自动添加原帧率播放标记；iOS 17 相册可能忽略此标记。")
                        }
                    }
                    .font(.footnote).foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                }
            }
        }
    }

    private func qualityRow(_ quality: VideoQuality) -> some View {
        let selected = model.qualityID == quality.id
        return Button { model.qualityID = quality.id } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(quality.id == "original" ? "原画 · \(quality.label)" : quality.label)
                        .font(.body.weight(selected ? .semibold : .regular))
                    if let bytes = quality.byteCount {
                        Text(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
                            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
                Spacer()
                Image(systemName: "checkmark")
                    .font(.body.weight(.semibold))
                    .opacity(selected ? 1 : 0)
            }
            .padding(.horizontal, 16).frame(minHeight: 56)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var originalRow: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("原画").font(.body)
                Text("最高画质 · 获取前确认费用").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("获取") { Task { await model.fetchOriginal() } }
                .buttonStyle(.secondary(height: 34))
                .font(.subheadline.weight(.semibold))
                .disabled(locked)
        }
        .padding(.horizontal, 16).frame(minHeight: 60)
    }

    private func photoResult(_ video: VideoInfo) -> some View {
        let allSelected = model.selectedPhotoIDs.count == video.photos.count
        return VStack(alignment: .leading, spacing: 24) {
            summary(video, thumbnail: video.photos.first?.imageURLs.first)
            if video.motionCount > 0 {
                VStack(alignment: .leading, spacing: 10) {
                    Text("保存为").sectionLabel()
                    Picker("保存为", selection: $model.photoMode) {
                        ForEach(PhotoSaveMode.allCases) { Text($0.shortTitle).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
            }
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("已选 \(model.selectedPhotoIDs.count) / \(video.photos.count)").sectionLabel().monospacedDigit()
                    Spacer()
                    Button(allSelected ? "取消全选" : "全选") {
                        model.selectedPhotoIDs = allSelected ? [] : Set(video.photos.map(\.id))
                    }
                    .font(.footnote.weight(.semibold)).foregroundStyle(.primary)
                }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 3), spacing: 4) {
                    ForEach(video.photos) { photoTile($0) }
                }
                if video.photos.contains(where: { $0.qualities.count > 1 }) {
                    Text("长按实况图片可选择动态画质").font(.caption).foregroundStyle(.tertiary)
                }
            }
        }
        .disabled(model.busy)
    }

    private func photoTile(_ photo: PhotoInfo) -> some View {
        let selected = model.selectedPhotoIDs.contains(photo.id)
        return Button {
            if selected { model.selectedPhotoIDs.remove(photo.id) } else { model.selectedPhotoIDs.insert(photo.id) }
        } label: {
            RemoteImage(url: photo.imageURLs.first)
                .aspectRatio(3 / 4, contentMode: .fit)
                .overlay { if !selected { Color(uiColor: .systemBackground).opacity(0.55) } }
                .overlay(alignment: .topLeading) {
                    if !photo.motionURLs.isEmpty {
                        Image(systemName: "livephoto")
                            .font(.caption.weight(.semibold)).foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.4), radius: 2)
                            .padding(7)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    ZStack {
                        Circle().fill(selected ? Color.primary : Color.black.opacity(0.25))
                        Circle().strokeBorder(.white, lineWidth: 1.5)
                        if selected {
                            Image(systemName: "checkmark").font(.caption2.weight(.heavy))
                                .foregroundStyle(Color(uiColor: .systemBackground))
                        }
                    }
                    .frame(width: 22, height: 22)
                    .padding(7)
                }
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .animation(.easeOut(duration: 0.15), value: selected)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("第 \(photo.id + 1) 张\(photo.motionURLs.isEmpty ? "" : "，实况")")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .contextMenu {
            if photo.qualities.count > 1 {
                Picker("动态画质", selection: Binding(
                    get: { model.motionQualityIDs[photo.id] ?? photo.qualities[0].id },
                    set: { model.motionQualityIDs[photo.id] = $0 })) {
                    ForEach(photo.qualities) { quality in
                        Text(quality.byteCount.map { quality.label + " · " + ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? quality.label)
                            .tag(quality.id)
                    }
                }
            }
        }
    }

    // MARK: Actions

    private func actionBar(_ video: VideoInfo) -> some View {
        HStack(spacing: 12) {
            Button { Task { await model.saveToPhotos() } } label: {
                Text(video.isPhotoPost ? "保存 \(model.selectedPhotoIDs.count) 项到相册" : "保存到相册")
            }
            .buttonStyle(.primary)

            Group {
                if model.selectedQuality?.id == "original" {
                    Menu {
                        Button("导出原始文件", systemImage: "doc") { Task { await model.export() } }
                        Button("导出相册兼容副本", systemImage: "film") { Task { await model.export(compatibleCopy: true) } }
                    } label: {
                        exportLabel
                    }
                    .menuStyle(.button)
                } else {
                    Button { Task { await model.export() } } label: { exportLabel }
                }
            }
            .buttonStyle(.secondary)
            .accessibilityLabel("导出文件")
        }
        .disabled(model.busy || !model.canSave)
        .padding(.horizontal, Theme.gutter)
        .padding(.top, 20).padding(.bottom, 10)
        .frame(maxWidth: 640)
        .frame(maxWidth: .infinity)
        .background {
            LinearGradient(stops: [.init(color: Color(uiColor: .systemBackground).opacity(0), location: 0),
                                   .init(color: Color(uiColor: .systemBackground), location: 0.35)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
        }
    }

    private var exportLabel: some View {
        Image(systemName: "square.and.arrow.up").font(.body.weight(.semibold)).offset(y: -1)
    }

    private func copy(_ text: String, notice: String) {
        UIPasteboard.general.string = text
        model.notice = notice
    }
}
