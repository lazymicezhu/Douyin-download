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
        NavigationStack {
            List {
                platformUsageSection

                Section {
                    Picker("本机历史范围", selection: $period) {
                        Text("今日").tag(HistoryPeriod.today)
                        Text("全部").tag(HistoryPeriod.all)
                    }
                    .pickerStyle(.segmented)

                    HistoryAmountsView(
                        normal: estimatedSum(\.estimatedNormalDebit),
                        gift: estimatedSum(\.estimatedGiftDebit),
                        total: estimatedSum(\.estimatedTotalDebit)
                    )

                    HStack {
                        Text("已推算 \(reconciled.count) 笔")
                        Spacer()
                        Text("待核实 \(pendingCount) 笔")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                } header: {
                    Text("本机历史 · 已推算费用")
                } footer: {
                    Text("按请求前后的余额变化推算，仅汇总能计算余额差的记录。基础报价不作为扣款金额。上方平台用量始终为平台当日数据。")
                }

                if let error = store.storageError {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.subheadline)
                            .foregroundStyle(.orange)
                    }
                }

                Section {
                    if accountID == nil {
                        ContentUnavailableView("尚未配置 API Key", systemImage: "key", description: Text("配置 API Key 后，可查看平台用量和这枚密钥对应的本机记录。"))
                    } else if entries.isEmpty {
                        ContentUnavailableView(period == .today ? "今日暂无本机记录" : "暂无本机记录", systemImage: "clock", description: Text("发出查询后，记录会出现在这里。"))
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
                    Text("本机请求 · \(entries.count) 笔")
                } footer: {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("从 2.1 版本开始，仅记录本机已发送的请求；不含旧版本和其他工具的历史。确认前取消的操作、免费的余额轮询不计入记录。")
                        Text("本机历史按 API Key 分组，更换密钥会分开显示，即使属于同一 TikHub 账户。")
                        Text("同账户并发消费可能影响前后余额差，最终账单以 TikHub 后台为准。")
                    }
                }
            }
            .navigationTitle("费用历史")
            .refreshable {
                guard accountID != nil else { return }
                await billing.refreshDailyUsage()
            }
            .task(id: accountID) {
                guard accountID != nil else { return }
                await billing.refreshDailyUsage()
            }
        }
        .id(accountID ?? "unconfigured")
    }

    private var platformUsageSection: some View {
        Section {
            if let usage = billing.dailyUsage, accountID != nil {
                HStack {
                    Text("平台日期：\(usage.date)")
                    Spacer(minLength: 6)
                    if billing.refreshingUsage { ProgressView().controlSize(.small) }
                }
                .font(.subheadline)

                HistoryAmountsView(normal: usage.normalUsed, gift: usage.giftUsed, total: usage.totalUsed)

                if let count = usage.paidRequests {
                    LabeledContent("收费请求数", value: "\(count)")
                        .font(.subheadline)
                }
                Text("更新于 \(usage.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if billing.refreshingUsage {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("正在读取平台当日用量…").foregroundStyle(.secondary)
                }
                .font(.subheadline)
            } else {
                Text(accountID == nil ? "配置 API Key 后可读取平台当日用量。" : "暂无平台当日用量，可下拉刷新。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if let error = billing.usageError, accountID != nil {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        } header: {
            Text("平台当日用量")
        } footer: {
            Text("包含同一账户通过其他设备、其他工具产生的请求。日期以平台返回为准；此汇总不会分摊到下方的本机记录。")
        }
    }

    private func historyRow(_ entry: HistoryEntry) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top, spacing: 12) {
                Text(entry.title)
                    .font(.headline)
                    .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .trailing, spacing: 3) {
                    Text(entry.estimatedTotalDebit.map(Money.usd) ?? "待核实")
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()
                    if entry.estimatedTotalDebit != nil {
                        Text("已推算").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            HStack(spacing: 8) {
                HistoryStatusView(outcome: entry.status, label: entry.statusLabel)
                Spacer(minLength: 6)
                Text(entry.startedAt, format: .dateTime.month(.twoDigits).day(.twoDigits).hour().minute())
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
            Text(entry.fundingLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
    }
}

private enum HistoryPeriod: Hashable { case today, all }

private struct HistoryAmountsView: View {
    let normal: Decimal?
    let gift: Decimal?
    let total: Decimal?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            amount("赠送", value: gift)
            amount("正常", value: normal)
            amount("合计", value: total)
        }
        .padding(.vertical, 6)
    }

    private func amount(_ title: String, value: Decimal?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value.map(Money.usd) ?? "—")
                .font(.headline)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.65)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

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
                    Text(entry.title).font(.headline)
                    HistoryStatusView(outcome: entry.status, label: entry.statusLabel)
                    LabeledContent("发送时间") {
                        Text(entry.startedAt.formatted(date: .abbreviated, time: .standard))
                    }
                    if let date = entry.finishedAt {
                        LabeledContent("结束时间") {
                            Text(date.formatted(date: .abbreviated, time: .standard))
                        }
                    }
                }

                Section {
                    LabeledContent("赠送余额 · 已推算", value: entry.estimatedGiftDebit.map(Money.usd) ?? "待核实")
                    LabeledContent("正常余额 · 已推算", value: entry.estimatedNormalDebit.map(Money.usd) ?? "待核实")
                    LabeledContent("合计 · 已推算", value: entry.estimatedTotalDebit.map(Money.usd) ?? "待核实")
                    LabeledContent("金额来源", value: entry.fundingLabel)
                    LabeledContent("基础报价", value: Money.usd(entry.quotedCost))
                } header: {
                    Text("费用")
                } footer: {
                    Text("基础报价用于请求前确认，不代表实际扣款。已推算金额来自余额差，可能受同账户其他消费影响。")
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

                balanceSection("请求前余额", balance: entry.before)
                balanceSection("请求后余额", balance: entry.after)

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

    private func balanceSection(_ title: String, balance: HistoryBalance?) -> some View {
        Section(title) {
            if let balance {
                LabeledContent("正常余额", value: Money.usd(balance.balance))
                LabeledContent("赠送余额", value: balance.freeCredit.map(Money.usd) ?? "未返回")
                Text("记录时间：\(balance.updatedAt.formatted(date: .abbreviated, time: .standard))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("暂无余额记录").font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }
}
