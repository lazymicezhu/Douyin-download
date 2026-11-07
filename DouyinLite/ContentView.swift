import SwiftUI
import UIKit

@MainActor
struct ContentView: View {
    private enum Tab: Hashable { case download, explore, account }

    @StateObject private var billing: BillingCenter
    @StateObject private var model: DownloadModel
    @State private var selectedTab = Tab.download
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
            DownloadView(model: model, billing: billing,
                         openSettings: { showingSettings = true },
                         openAccount: { selectedTab = .account })
                .tabItem { Label("下载", systemImage: "arrow.down.circle") }.tag(Tab.download)
            ExploreView(billing: billing)
                .tabItem { Label("查询", systemImage: "magnifyingglass") }.tag(Tab.explore)
            AccountView(model: model, billing: billing)
                .tabItem { Label("我的", systemImage: "person.crop.circle") }.tag(Tab.account)
        }
        .sheet(isPresented: $showingSettings) {
            NavigationStack {
                SettingsView(model: model)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) { Button("完成") { showingSettings = false } }
                    }
            }
            .onChange(of: model.hasAPIKey) { _, configured in
                if configured { showingSettings = false }
            }
        }
        .sheet(item: Binding(get: { billing.pendingCharge }, set: { if $0 == nil { billing.answerCharge(approved: false) } })) { prompt in
            ChargeConfirmationView(prompt: prompt, balance: billing.account?.balance) { approved in
                billing.answerCharge(approved: approved)
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
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
                    showingSettings = false
                    selectedTab = .download
                    importMessage = "配置已导入，密钥已保存到本机。"
                } catch is CancellationError { }
                catch { importMessage = error.localizedDescription }
            }
        }
        .alert("导入配置", isPresented: Binding(get: { importMessage != nil }, set: { if !$0 { importMessage = nil } })) {
            Button("好", role: .cancel) { importMessage = nil }
        } message: { Text(importMessage ?? "") }
    }
}

struct ChargeConfirmationView: View {
    let prompt: ChargePrompt
    let balance: Decimal?
    let answer: (Bool) -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                VStack(spacing: 10) {
                    Text(prompt.title)
                        .font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
                    Text(Money.usd(prompt.quote.amount))
                        .font(.system(size: 48, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .minimumScaleFactor(0.5).lineLimit(1)
                    HStack(spacing: 6) {
                        if let balance { Text("余额 \(Money.usd(balance))").monospacedDigit() }
                        if prompt.quote.allowsDiscount { Text("· 阶梯优惠") }
                        if prompt.quote.allowsFreeCredit { Text("· 可用赠送额度") }
                    }
                    .font(.footnote).foregroundStyle(.secondary)
                }
                .padding(.top, 20)

                VStack(spacing: 12) {
                    Button("确认并查询") { answer(true) }
                        .buttonStyle(.primary)
                    Button("取消", role: .cancel) { answer(false) }
                        .buttonStyle(.secondaryWide)
                }

                Text("按基础价确认，实际扣款以 TikHub 账单为准。只发送 1 次请求、不自动重试；发出后取消仍可能计费。")
                    .font(.caption).foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 24).padding(.vertical, 16)
            .frame(maxWidth: 480).frame(maxWidth: .infinity)
        }
    }
}
