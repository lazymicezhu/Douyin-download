import SwiftUI

@MainActor
struct HistoryView: View {
    @ObservedObject var store: HistoryStore
    let accountID: String?
    @ObservedObject var billing: BillingCenter
    @State private var period: HistoryPeriod = .today

    private var entries: [HistoryEntry] {
        guard let accountID else { return [] }
        return store.entries(for: accountID)
            .filter { period == .all || Calendar.current.isDateInToday($0.startedAt) }
            .sorted { $0.startedAt > $1.startedAt }
    }

    private var reconciled: [HistoryEntry] {
        entries.filter { $0.estimatedTotalDebit != nil }
    }

    private var pendingCount: Int { entries.count - reconciled.count }

    private func estimatedSum(_ keyPath: KeyPath<HistoryEntry, Decimal?>) -> Decimal? {
        let amounts = reconciled.compactMap { $0[keyPath: keyPath] }
        return amounts.isEmpty ? nil : amounts.reduce(Decimal.zero, +)
    }

    var body: some View {
        List {
            platformUsageSection

            if let error = store.storageError {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.subheadline)
                        .foregroundStyle(.orange)
                }
            }

            Section {
                Picker("范围", selection: $period) {
                    Text("今日").tag(HistoryPeriod.today)
                    Text("全部").tag(HistoryPeriod.all)
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())

                if accountID == nil {
                    ContentUnavailableView("尚未配置 API Key", systemImage: "key")
                } else if entries.isEmpty {
                    ContentUnavailableView(period == .today ? "今日暂无记录" : "暂无记录", systemImage: "clock",
                                           description: Text("发出付费查询后，记录会出现在这里。"))
                } else {
                    ForEach(entries) { entry in
                        NavigationLink {
                            HistoryDetailView(store: store, accountID: accountID ?? "", entryID: entry.id)
                        } label: {
                            historyRow(entry)
                        }
                    }
                }
            } header: {
                HStack {
                    Text("本机记录")
                    Spacer()
                    if !entries.isEmpty {
                        Text(localSummary).monospacedDigit().textCase(nil)
                    }
                }
            }

            Section {
                DisclosureGroup("关于这些数据") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("平台用量来自 TikHub，包含同一账户在其他设备和工具上的请求。")
                        Text("本机记录按请求前后的余额差推算扣款，仅包含本机已发送的请求，按 API Key 分组；同账户并发消费可能影响推算，最终以 TikHub 账单为准。")
                        Text("确认前取消的操作和免费的余额查询不计入。")
                    }
                    .font(.footnote).foregroundStyle(.secondary)
                    .padding(.vertical, 4)
                }
                .font(.subheadline)
            }
        }
        .navigationTitle("费用明细")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            guard accountID != nil else { return }
            await billing.refreshDailyUsage(force: true)
        }
        .task(id: accountID) {
            guard accountID != nil else { return }
            await billing.refreshDailyUsage()
        }
        .id(accountID ?? "unconfigured")
    }

    private var localSummary: String {
        var parts: [String] = []
        if let total = estimatedSum(\.estimatedTotalDebit) { parts.append("约 \(Money.usd(total))") }
        if pendingCount > 0 { parts.append("\(pendingCount) 笔待核实") }
        return parts.isEmpty ? "\(entries.count) 笔" : parts.joined(separator: " · ")
    }

    private var platformUsageSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("今日平台用量").font(.subheadline).foregroundStyle(.secondary)
                    Spacer()
                    if billing.refreshingUsage { ProgressView().controlSize(.small) }
                    else if let usage = billing.dailyUsage, accountID != nil {
                        Text(usage.date).font(.caption).foregroundStyle(.tertiary)
                    }
                }
                if let usage = billing.dailyUsage, accountID != nil {
                    Text(Money.usd(usage.totalUsed))
                        .font(.system(size: 36, weight: .semibold, design: .rounded))
                        .monospacedDigit().lineLimit(1).minimumScaleFactor(0.5)
                    HStack(spacing: 16) {
                        Label(Money.usd(usage.normalUsed), systemImage: "dollarsign.circle")
                        Label(Money.usd(usage.giftUsed), systemImage: "gift")
                        if let count = usage.paidRequests {
                            Label("\(count) 次", systemImage: "arrow.up.arrow.down")
                        }
                    }
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                } else {
                    Text(accountID == nil ? "未连接" : (billing.refreshingUsage ? "正在读取…" : "暂无数据，下拉刷新"))
                        .font(.title3.weight(.semibold)).foregroundStyle(.secondary)
                }
                if let error = billing.usageError, accountID != nil {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            .padding(.vertical, 6)
        }
    }

    private func historyRow(_ entry: HistoryEntry) -> some View {
        HStack(spacing: 12) {
            HistoryStatusView(outcome: entry.status, label: entry.statusLabel)
                .labelStyle(.iconOnly)
                .font(.title3)
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.title).font(.subheadline.weight(.medium)).lineLimit(1)
                Text(entry.startedAt, format: .dateTime.month(.twoDigits).day(.twoDigits).hour().minute())
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Text(entry.estimatedTotalDebit.map(Money.usd) ?? "待核实")
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(entry.estimatedTotalDebit == nil ? .secondary : .primary)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

private enum HistoryPeriod: Hashable { case today, all }

private struct HistoryStatusView: View {
    let outcome: HistoryOutcome
    let label: String

    private var symbol: String {
        switch outcome {
        case .sent: return "clock"
        case .succeeded: return "checkmark.circle"
        case .failed: return "exclamationmark.circle"
        case .cancelled: return "xmark.circle"
        case .interrupted: return "pause.circle"
        }
    }

    private var color: Color {
        switch outcome {
        case .succeeded: return .green
        case .failed: return .orange
        case .sent, .cancelled, .interrupted: return .secondary
        }
    }

    var body: some View {
        Label(label, systemImage: symbol).foregroundStyle(color)
    }
}

@MainActor
private struct HistoryDetailView: View {
    @ObservedObject var store: HistoryStore
    let accountID: String
    let entryID: UUID

    private var entry: HistoryEntry? {
        store.entries(for: accountID).first { $0.id == entryID }
    }

    var body: some View {
        List {
            if let entry {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(entry.title).font(.headline)
                        HistoryStatusView(outcome: entry.status, label: entry.statusLabel).font(.subheadline)
                    }
                    LabeledContent("发送时间") {
                        Text(entry.startedAt.formatted(date: .abbreviated, time: .standard))
                    }
                }

                Section {
                    LabeledContent("推算扣款", value: entry.estimatedTotalDebit.map(Money.usd) ?? "待核实")
                    if entry.estimatedTotalDebit != nil {
                        LabeledContent("其中正常余额", value: entry.estimatedNormalDebit.map(Money.usd) ?? "—")
                        LabeledContent("其中赠送余额", value: entry.estimatedGiftDebit.map(Money.usd) ?? "—")
                    }
                    LabeledContent("基础报价", value: Money.usd(entry.quotedCost))
                } header: {
                    Text("费用")
                } footer: {
                    Text(entry.fundingLabel + "。推算金额来自请求前后余额差，基础报价不代表实际扣款。")
                }

                if let message = entry.failureMessage, !message.isEmpty {
                    Section("请求说明") {
                        Text(message).font(.subheadline).textSelection(.enabled)
                    }
                }

                if let note = entry.reconciliationNote, !note.isEmpty {
                    Section("核对说明") {
                        Text(note).font(.subheadline).textSelection(.enabled)
                    }
                } else if entry.estimatedTotalDebit == nil {
                    Section("核对说明") {
                        Text("暂时没有可用于计算本次余额差的前后余额数据。请以 TikHub 后台账单为准。")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }

                if entry.before != nil || entry.after != nil {
                    Section("余额变化") {
                        balanceChange("正常余额", entry.before?.balance, entry.after?.balance)
                        balanceChange("赠送余额", entry.before?.freeCredit, entry.after?.freeCredit)
                    }
                }

                Section("请求信息") {
                    if let status = entry.httpStatus {
                        LabeledContent("HTTP 状态", value: "\(status)")
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("请求 ID").font(.caption).foregroundStyle(.secondary)
                        Text(entry.requestID ?? "未返回")
                            .font(.subheadline)
                            .textSelection(.enabled)
                    }
                    DisclosureGroup("接口信息") {
                        LabeledContent("请求方式", value: entry.method)
                        Text(entry.path)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
            } else {
                ContentUnavailableView("没有找到这条记录", systemImage: "doc.text.magnifyingglass")
            }
        }
        .navigationTitle("费用详情")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func balanceChange(_ title: String, _ before: Decimal?, _ after: Decimal?) -> some View {
        LabeledContent(title) {
            Text("\(before.map(Money.usd) ?? "—") → \(after.map(Money.usd) ?? "—")").monospacedDigit()
        }
    }
}
