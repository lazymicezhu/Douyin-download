import Foundation
import Combine
import CryptoKit

struct HistoryBalance: Codable, Equatable {
    let balance: Decimal
    let freeCredit: Decimal?
    let updatedAt: Date

    init(_ value: AccountBalance) {
        balance = value.balance
        freeCredit = value.freeCredit
        updatedAt = value.updatedAt
    }
}

enum HistoryOutcome: String, Codable {
    case sent, succeeded, failed, cancelled, interrupted
}

struct HistoryEntry: Identifiable, Codable, Equatable {
    let id: UUID
    let accountID: String
    let startedAt: Date
    var finishedAt: Date?
    let title: String
    let path: String
    let method: String
    let quotedCost: Decimal
    let allowsFreeCredit: Bool
    var status: HistoryOutcome
    var httpStatus: Int?
    var requestID: String?
    let before: HistoryBalance?
    var after: HistoryBalance?
    var reconciliationNote: String?
    var failureMessage: String? = nil

    private var estimatedDebits: (normal: Decimal, gift: Decimal)? {
        if quotedCost == 0 { return (0, 0) }
        guard let before, let after, let freeBefore = before.freeCredit, let freeAfter = after.freeCredit,
              after.updatedAt > before.updatedAt,
              after.updatedAt.timeIntervalSince(before.updatedAt) <= 120,
              before.updatedAt <= startedAt,
              startedAt.timeIntervalSince(before.updatedAt) <= 15 else { return nil }
        let normal = Self.rounded(before.balance - after.balance)
        let gift = Self.rounded(freeBefore - freeAfter)
        guard normal >= 0, gift >= 0, normal + gift > 0,
              normal + gift <= quotedCost + Decimal(string: "0.00000001")!,
              allowsFreeCredit || gift == 0 else { return nil }
        return (normal, gift)
    }

    var estimatedNormalDebit: Decimal? { estimatedDebits?.normal }
    var estimatedGiftDebit: Decimal? { estimatedDebits?.gift }
    var estimatedTotalDebit: Decimal? { estimatedDebits.map { $0.normal + $0.gift } }
    var fundingLabel: String {
        guard let amounts = estimatedDebits else { return "扣款来源待核实" }
        if quotedCost == 0 { return "免费接口（按当前报价）" }
        if amounts.normal > 0 && amounts.gift > 0 { return "赠送＋正常余额（推算）" }
        return amounts.gift > 0 ? "赠送余额（推算）" : "正常余额（推算）"
    }
    var statusLabel: String {
        switch status {
        case .sent: return "请求中"
        case .succeeded: return "查询成功"
        case .failed: return "查询失败"
        case .cancelled: return "请求已取消"
        case .interrupted: return "上次请求中断"
        }
    }
    private static func rounded(_ amount: Decimal) -> Decimal {
        var input = amount, result = Decimal()
        NSDecimalRound(&result, &input, 8, .plain)
        return result
    }
}

@MainActor
final class HistoryStore: ObservableObject {
    @Published private(set) var entries: [HistoryEntry] = []
    @Published private(set) var storageError: String?
    private let fileURL: URL?
    private var loadFailed = false

    init(fileURL: URL? = HistoryStore.defaultURL) {
        self.fileURL = fileURL
        guard let fileURL, FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            entries = try JSONDecoder().decode([HistoryEntry].self, from: Data(contentsOf: fileURL))
            var changed = false
            for index in entries.indices where entries[index].status == .sent {
                entries[index].status = .interrupted
                entries[index].reconciliationNote = "上次运行在请求结束前中断，扣费是否发生待核实。"
                changed = true
            }
            if changed { try persist() }
        } catch {
            loadFailed = true
            storageError = "无法读取历史记录，已保留原文件。为避免丢失账目，暂不发出新查询。"
        }
    }

    nonisolated static var defaultURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("DouyinLite", isDirectory: true).appendingPathComponent("query-history.json")
    }

    static func identity(for key: String) -> String {
        SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func entries(for accountID: String) -> [HistoryEntry] {
        entries.filter { $0.accountID == accountID }.sorted { $0.startedAt > $1.startedAt }
    }

    func begin(request: APIRequest, quote: EndpointQuote, accountID: String, before: AccountBalance?) throws -> UUID {
        guard !loadFailed else { throw AppError.message(storageError ?? "历史记录不可用。") }
        let entry = HistoryEntry(id: UUID(), accountID: accountID, startedAt: Date(), finishedAt: nil,
                                 title: request.title, path: request.path, method: request.method,
                                 quotedCost: quote.amount, allowsFreeCredit: quote.allowsFreeCredit,
                                 status: .sent, httpStatus: nil, requestID: nil,
                                 before: before.map(HistoryBalance.init), after: nil,
                                 reconciliationNote: quote.amount > 0 ? "等待请求结束后的免费余额核对。" : "定价接口返回本次基础费用为零。")
        entries.append(entry)
        do { try persist() }
        catch {
            entries.removeAll { $0.id == entry.id }
            storageError = "历史记录写入失败，本次查询未发送。请检查手机剩余空间。"
            throw AppError.message(storageError!)
        }
        return entry.id
    }

    func complete(_ id: UUID, outcome: HistoryOutcome, response: APIResponse?, note: String?) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].status = outcome
        entries[index].finishedAt = Date()
        entries[index].httpStatus = response?.status
        if let data = response?.data, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let requestID = object["request_id"] as? String, requestID.count <= 128,
           requestID.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_:")).contains($0) }) {
            entries[index].requestID = requestID
        }
        entries[index].failureMessage = outcome == .succeeded ? nil : note
        entries[index].reconciliationNote = "正在核对两种余额的变化。"
        saveChanges()
    }

    func reconcile(_ id: UUID, after: AccountBalance?, note: String? = nil) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].after = after.map(HistoryBalance.init)
        let entry = entries[index]
        if entry.quotedCost == 0 {
            entries[index].reconciliationNote = "本次接口基础报价为零，不计入收费查询估算。"
        } else if entry.estimatedTotalDebit != nil {
            entries[index].reconciliationNote = "根据请求前后余额变化推算，并非平台逐笔账单；同账户其他工具消费可能影响结果。"
        } else {
            let reason: String
            if entry.before == nil || after == nil { reason = "未取得完整的前后余额快照。" }
            else if entry.before?.balance == entry.after?.balance && entry.before?.freeCredit == entry.after?.freeCredit {
                reason = "暂未观察到余额减少，可能尚未结算，不能据此认定免费。"
            } else { reason = "余额变化与本次报价不匹配，或核对间隔过长，可能有充值或其他消费。" }
            entries[index].reconciliationNote = reason + (note.map { " " + $0 } ?? "") + " 请结合平台当日用量或后台账单核实。"
        }
        saveChanges()
    }

    private func saveChanges() {
        do { try persist() }
        catch { storageError = "历史记录暂未写入磁盘，请检查手机剩余空间；当前页面仍保留本次记录。" }
    }

    private func persist() throws {
        guard let fileURL else { throw AppError.message("无法创建本机历史文件。") }
        let folder = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(entries)
        try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        var localFile = fileURL
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? localFile.setResourceValues(values)
        storageError = nil
    }
}
