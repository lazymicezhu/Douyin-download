import SwiftUI
import UIKit

@MainActor
struct ContentView: View {
    @StateObject private var billing: BillingCenter
    @StateObject private var model: DownloadModel
    @State private var selectedTab = 0
    @State private var showingSettings = false
    @State private var importMessage: String?
    @State private var importTask: Task<Void, Never>?
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let billing = BillingCenter()
        _billing = StateObject(wrappedValue: billing)
        _model = StateObject(wrappedValue: DownloadModel(billing: billing))
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            DownloadView(model: model, billing: billing, openSettings: { showingSettings = true })
                .tabItem { Label("下载", systemImage: "arrow.down.circle") }.tag(0)
            ExploreView(billing: billing)
                .tabItem { Label("查询", systemImage: "magnifyingglass") }.tag(1)
            HistoryView(store: billing.history, accountID: billing.historyAccountID, billing: billing)
                .tabItem { Label("历史", systemImage: "clock.arrow.circlepath") }.tag(3)
            accountView
                .tabItem { Label("账户", systemImage: "person.crop.circle") }.tag(2)
        }
        .sheet(isPresented: $showingSettings) { SettingsView(model: model) }
        .sheet(item: Binding(get: { billing.pendingCharge }, set: { if $0 == nil { billing.answerCharge(approved: false) } })) { prompt in
            chargeView(prompt)
                .presentationDetents([.medium, .large])
        }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            await billing.refreshBalance(force: true)
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
                await billing.refreshBalance()
            }
        }
        .onOpenURL { url in
            guard url.isFileURL else { return }
            importTask?.cancel()
            importTask = Task { @MainActor in
                do {
                    try await model.importConfiguration(url)
                    selectedTab = 2
                    importMessage = "配置已导入，密钥已保存到本机。"
                } catch is CancellationError { }
                catch { importMessage = error.localizedDescription }
            }
        }
        .alert("导入配置", isPresented: Binding(get: { importMessage != nil }, set: { if !$0 { importMessage = nil } })) {
            Button("好", role: .cancel) { importMessage = nil }
        } message: { Text(importMessage ?? "") }
    }

    private var accountView: some View {
        NavigationStack {
            Form {
                Section("TikHub 账户") {
                    if let account = billing.account {
                        LabeledContent("余额（美元）", value: Money.usd(account.balance))
                        if let credit = account.freeCredit { LabeledContent("赠送额度（美元）", value: Money.usd(credit)) }
                        LabeledContent("上次更新", value: account.updatedAt.formatted(date: .omitted, time: .standard))
                    } else { Text(billing.hasAPIKey ? "等待查询余额" : "导入配置后显示余额").foregroundStyle(.secondary) }
                    if let error = billing.accountError { Text(error).font(.footnote).foregroundStyle(.orange) }
                    Button { Task { await billing.refreshBalance(force: true) } } label: {
                        HStack { Text("刷新余额"); Spacer(); if billing.refreshing { ProgressView() } }
                    }.disabled(!billing.hasAPIKey || billing.refreshing)
                    Link("打开 TikHub 账户", destination: URL(string: "https://user.tikhub.io")!)
                }
                Section {
                    Button { showingSettings = true } label: { Label("API Key 与配置文件", systemImage: "key") }
                        .disabled(billing.isWorking || model.busy)
                } footer: {
                    Text("可导入 .txt / .env，或直接粘贴整段配置。密钥保存在本机钥匙串中。")
                }
                Section("费用说明") {
                    Text("每次查询先核对当前价格，再由你确认。翻页、重新获取链接、获取原画都会分别确认。查不到价格时不会执行查询。")
                    Text("确认页显示美元基础价；阶梯优惠和赠送额度可能降低实际扣款，以 TikHub 账单为准。接口已发出后取消，不能撤回服务端可能发生的计费。")
                    Text("下载已获取的素材、切换已有画质、合成实况、保存相册不会再次调用付费解析接口。")
                    Text("余额在 App 前台每 30 秒和查询后刷新。每次先验证余额接口仍免费；网络失败会保留旧余额并显示提示。")
                }.font(.subheadline)
                Section {
                    Text("抖取 2.1 · 视频 / 图文 / 实况")
                    Text("支持 iOS 17 及以上")
                }.foregroundStyle(.secondary)
            }.navigationTitle("账户")
        }
    }

    private func chargeView(_ prompt: ChargePrompt) -> some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Label("本次将调用 1 次接口", systemImage: "creditcard").font(.headline)
                    Text(prompt.title).font(.title2.bold())
                    Text(Money.usd(prompt.quote.amount) + " USD").font(.system(size: 36, weight: .bold, design: .rounded))
                    Text("本次基础费用").font(.subheadline).foregroundStyle(.secondary)
                    if prompt.quote.allowsDiscount {
                        Text("此接口支持阶梯优惠，实际扣款可能低于基础价，以 TikHub 账单为准。")
                    }
                    if prompt.quote.allowsFreeCredit {
                        Text("此接口支持赠送额度；可用额度由 TikHub 结算。")
                    }
                    if let account = billing.account {
                        Text("上次查询余额：\(Money.usd(account.balance)) USD").font(.footnote).foregroundStyle(.secondary)
                    }
                    Text("确认后才发出请求，不会自动重试。请求发出后取消，仍可能计费。").font(.footnote).foregroundStyle(.secondary)
                    Button("确认查询 · \(Money.usd(prompt.quote.amount))") { billing.answerCharge(approved: true) }
                        .buttonStyle(.borderedProminent).controlSize(.large).frame(maxWidth: .infinity)
                    Button("取消") { billing.answerCharge(approved: false) }.frame(maxWidth: .infinity)
                }.padding(24)
            }.navigationTitle("确认费用").navigationBarTitleDisplayMode(.inline)
        }
    }
}

@MainActor
private struct DownloadView: View {
    @ObservedObject var model: DownloadModel
    @ObservedObject var billing: BillingCenter
    let openSettings: () -> Void
    @FocusState private var inputIsFocused: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    inputSection
                    if let account = billing.account {
                        VStack(alignment: .leading, spacing: 4) {
                            Label("余额 \(Money.usd(account.balance)) USD", systemImage: "creditcard")
                            Text(billing.accountError == nil ? "更新于 \(account.updatedAt.formatted(date: .omitted, time: .standard))" : "余额更新失败，显示上次结果")
                        }.font(.footnote).foregroundStyle(.secondary)
                    }
                    if !model.hasAPIKey {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("首次使用请导入配置", systemImage: "key").font(.headline)
                            Text("导入配置文件，或直接粘贴文件中的文字。").font(.subheadline).foregroundStyle(.secondary)
                            Button("打开设置", action: openSettings)
                        }.card()
                    }
                    HStack {
                        if model.busy { ProgressView() }
                        Text(model.status).font(.subheadline).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                        if model.canCancel { Button("取消") { model.cancel() } }
                    }
                    if let error = model.errorMessage {
                        Label(error, systemImage: "exclamationmark.circle").font(.subheadline).foregroundStyle(.red).textSelection(.enabled)
                    }
                    if let video = model.video { result(video) }
                }
                .padding(20).frame(maxWidth: 620).frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("抖取")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: openSettings) { Image(systemName: "gearshape") }
                        .accessibilityLabel("设置").disabled(model.busy || billing.isWorking)
                }
            }
        }
    }

    private var inputSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("视频、图文、实况，一次获取").font(.headline)
            Text("复制抖音分享链接，也可以粘贴整段文案。").font(.subheadline).foregroundStyle(.secondary)
            TextField("粘贴抖音分享链接…", text: $model.input, axis: .vertical)
                .lineLimit(3...6).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                .focused($inputIsFocused).padding(14)
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
                .disabled(model.busy)
            HStack {
                Button { if let text = UIPasteboard.general.string { model.input = text } } label: {
                    Label("粘贴", systemImage: "doc.on.clipboard")
                }.buttonStyle(.bordered).disabled(model.busy)
                Spacer()
                Button("获取作品") { inputIsFocused = false; Task { await model.resolve() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.busy || billing.isWorking || !model.hasAPIKey || model.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            Text("调用前显示费用，确认后才查询。").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func result(_ video: VideoInfo) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            if !video.isPhotoPost, let cover = video.coverURL { preview(cover).frame(height: 220) }
            Text(video.title.isEmpty ? "抖音作品" : video.title).font(.headline).textSelection(.enabled)
            if !video.author.isEmpty { Text(video.author).font(.subheadline).foregroundStyle(.secondary) }
            HStack {
                Button("复制文案") { UIPasteboard.general.string = video.title }
                Spacer()
                Button("复制作品 ID") { UIPasteboard.general.string = video.id }
            }.font(.caption)
            if video.isPhotoPost { photoOptions(video) } else { videoOptions(video) }
            Button { Task { await model.saveToPhotos() } } label: {
                Label(video.isPhotoPost ? "保存所选到相册" : "保存到相册", systemImage: "square.and.arrow.down")
                    .frame(maxWidth: .infinity)
            }.buttonStyle(.borderedProminent).controlSize(.large).disabled(model.busy || !model.canSave)
            if model.exportFiles.isEmpty {
                Button { Task { await model.download() } } label: {
                    Label("下载后导出文件", systemImage: "folder").frame(maxWidth: .infinity)
                }.buttonStyle(.bordered).controlSize(.large).disabled(model.busy || !model.canSave)
            } else {
                ShareLink(items: model.exportFiles) { Label("导出文件", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity) }
                    .buttonStyle(.bordered).controlSize(.large).disabled(model.busy)
            }
            Button("链接失效？重新获取（需查询费用）") { Task { await model.resolve(refresh: true) } }
                .font(.caption).disabled(model.busy || billing.isWorking)
        }.card()
    }

    private func videoOptions(_ video: VideoInfo) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if !video.qualities.isEmpty {
                Picker("下载画质", selection: $model.qualityID) {
                    ForEach(video.qualities) { quality in Text(quality.label).tag(quality.id) }
                }.pickerStyle(.menu).disabled(model.busy)
                if let quality = model.selectedQuality, let bytes = quality.byteCount {
                    Text("文件大小约 \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))").font(.caption).foregroundStyle(.secondary)
                }
            }
            Text("显示此作品实际返回的画质；切换已有选项不再次计费。").font(.caption).foregroundStyle(.secondary)
            if model.selectedQuality?.id == "original" {
                Text("保存到相册时添加原帧率播放标记，避免 120fps 原画被默认慢放；保留原画分辨率、帧率和音轨，不重新压缩。导出文件保留原始源文件。")
                    .font(.caption).foregroundStyle(.secondary)
                if #unavailable(iOS 18) {
                    Text("iOS 17 相册可能忽略播放标记；建议在 iOS 18 或更新版本使用。").font(.caption).foregroundStyle(.orange)
                }
                if let compatible = model.compatibleVideoFile {
                    ShareLink(item: compatible) { Label("导出已添加播放标记的副本", systemImage: "film") }
                        .font(.caption).disabled(model.busy)
                }
            }
            Button(video.qualities.contains(where: { $0.id == "original" }) ? "选择已获取的原画" : "获取原画 · 先确认费用") {
                Task { await model.fetchOriginal() }
            }.buttonStyle(.bordered).disabled(model.busy || billing.isWorking)
        }
    }

    private func photoOptions(_ video: VideoInfo) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("已选 \(model.selectedPhotoIDs.count) / \(video.photos.count) 张").font(.subheadline)
                Spacer()
                Button(model.selectedPhotoIDs.count == video.photos.count ? "全不选" : "全选") {
                    model.selectedPhotoIDs = model.selectedPhotoIDs.count == video.photos.count ? [] : Set(video.photos.map(\.id))
                }.font(.subheadline)
            }
            if video.motionCount > 0 {
                Picker("保存方式", selection: $model.photoMode) {
                    ForEach(PhotoSaveMode.allCases) { mode in Text(mode.rawValue).tag(mode) }
                }.pickerStyle(.menu)
                Text("实况会在本机合成。也可单独保留图片和视频；普通图片按静图保存。").font(.caption).foregroundStyle(.secondary)
            }
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                ForEach(video.photos) { photo in
                    VStack(alignment: .leading, spacing: 7) {
                        Button {
                            if model.selectedPhotoIDs.contains(photo.id) { model.selectedPhotoIDs.remove(photo.id) }
                            else { model.selectedPhotoIDs.insert(photo.id) }
                        } label: {
                            ZStack(alignment: .topTrailing) {
                                if let url = photo.imageURLs.first { preview(url).frame(height: 150).clipped() }
                                Image(systemName: model.selectedPhotoIDs.contains(photo.id) ? "checkmark.circle.fill" : "circle")
                                    .symbolRenderingMode(.palette).foregroundStyle(.white, .blue)
                                    .font(.title2).padding(7)
                            }
                        }.buttonStyle(.plain)
                        Text("第 \(photo.id + 1) 张\(photo.motionURLs.isEmpty ? "" : " · 实况")").font(.caption)
                        if photo.qualities.count > 1 {
                            Picker("动态画质", selection: Binding(get: { model.motionQualityIDs[photo.id] ?? photo.qualities[0].id }, set: { model.motionQualityIDs[photo.id] = $0 })) {
                                ForEach(photo.qualities) { Text($0.label).tag($0.id) }
                            }.pickerStyle(.menu).font(.caption)
                        }
                    }
                }
            }
        }.disabled(model.busy)
    }

    private func preview(_ url: URL) -> some View {
        AsyncImage(url: url) { phase in
            if let image = phase.image { image.resizable().scaledToFit() }
            else if phase.error != nil { Image(systemName: "photo").font(.largeTitle).foregroundStyle(.secondary) }
            else { ProgressView() }
        }
        .frame(maxWidth: .infinity)
        .background(Color(uiColor: .tertiarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

private extension View {
    func card() -> some View {
        self.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
    }
}
