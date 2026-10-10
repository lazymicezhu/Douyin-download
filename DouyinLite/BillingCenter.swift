import Foundation
import Combine

struct ChargePrompt: Identifiable {
    let id = UUID()
    let title: String
    let quote: EndpointQuote
}

@MainActor
final class BillingCenter: ObservableObject {
    @Published private(set) var pendingCharge: ChargePrompt?
    @Published private(set) var account: AccountBalance?
    @Published private(set) var accountError: String?
    @Published private(set) var refreshing = false
    @Published private(set) var isWorking = false
    @Published private(set) var hasAPIKey: Bool
    @Published private(set) var historyAccountID: String?
    @Published private(set) var dailyUsage: DailyUsage?
    @Published private(set) var usageError: String?
    @Published private(set) var refreshingUsage = false
    let history: HistoryStore
    private let transport: APITransporting
    private let readKey: () -> String?
    private var approval: CheckedContinuation<Void, Error>?
    private var generation = UUID()
    private var balanceAttempt: Date?
    private var usageAttempt: Date?
    private var accountTail: Task<AccountBalance, Error>?
    private var accountTaskID: UUID?
    private var accountLastSent: Date?
    static let accountPath = "/api/v1/tikhub/user/get_user_info"
    static let usagePath = "/api/v1/tikhub/user/get_user_daily_usage"

    init(transport: APITransporting = APITransport(), readKey: @escaping () -> String? = { KeyStore.read() }, history: HistoryStore? = nil) {
        self.transport = transport
        self.readKey = readKey
        self.history = history ?? HistoryStore()
        let key = readKey()
        self.hasAPIKey = key != nil
        self.historyAccountID = key.map(HistoryStore.identity(for:))
    }

    func credentialsChanged() {
        generation = UUID()
        answerCharge(approved: false)
        account = nil
        accountError = nil
        dailyUsage = nil
        usageError = nil
        balanceAttempt = nil
        usageAttempt = nil
        let key = readKey()
        hasAPIKey = key != nil
        historyAccountID = key.map(HistoryStore.identity(for:))
        Task { await refreshBalance(force: true) }
    }

    private func quote(_ path: String) async throws -> EndpointQuote {
        let response = try await transport.send(APIRequest(title: "核对价格", path: "/api/v1/tikhub/user/get_endpoint_info", query: ["endpoint": path], timeout: 12), apiKey: nil)
        return try EndpointQuote.decode(response, path: path)
    }

    /// All business queries use a fresh quote, one approval, and one dispatch.
    /// Reconciliation uses only freshly verified free account endpoints.
    func perform(_ request: APIRequest) async throws -> Data {
        guard !isWorking else { throw AppError.message("请等待当前查询完成。") }
        guard let key = readKey() else { throw AppError.message("请先在账户中导入配置或填写 API Key。") }
        isWorking = true
        let requestGeneration = generation
        defer { isWorking = false }
        let price = try await quote(request.path)
        try Task.checkCancellation()
        guard generation == requestGeneration else { throw CancellationError() }
        if price.amount > 0 {
            try await confirm(ChargePrompt(title: request.title, quote: price))
            try Task.checkCancellation()
            guard price.obtainedAt.timeIntervalSinceNow > -60 else {
                throw AppError.message("价格确认已超过一分钟。请重新查询以获取最新价格。")
            }
        }
        guard generation == requestGeneration, readKey() == key else { throw CancellationError() }
        var before: AccountBalance?
        if price.amount > 0 { before = try? await freshAccount(key: key) }
        try Task.checkCancellation()
        guard generation == requestGeneration, readKey() == key else { throw CancellationError() }
        if price.amount > 0, price.obtainedAt.timeIntervalSinceNow <= -60 {
            throw AppError.message("价格已过期，本次请求未发送，请重新查询。")
        }
        if let before { account = before; accountError = nil }
        let entryID = try history.begin(request: request, quote: price, accountID: HistoryStore.identity(for: key), before: before)
        var received: APIResponse?
        do {
            let response = try await transport.send(request, apiKey: key)
            received = response
            try Task.checkCancellation()
            guard generation == requestGeneration else { throw CancellationError() }
            _ = try APIJSON.object(response)
            history.complete(entryID, outcome: .succeeded, response: response, note: nil)
            await reconcile(entryID, key: key, generation: requestGeneration, paid: price.amount > 0)
            return response.data
        } catch {
            let cancelled = error is CancellationError || (error as? URLError)?.code == .cancelled
            history.complete(entryID, outcome: cancelled ? .cancelled : .failed, response: received,
                             note: cancelled ? "请求被取消，已发出的请求仍可能计费。" : "请求未成功，是否扣费需要核对余额。")
            await reconcile(entryID, key: key, generation: requestGeneration, paid: price.amount > 0)
            throw error
        }
    }

    private func reconcile(_ entryID: UUID, key: String, generation requestGeneration: UUID, paid: Bool) async {
        guard paid else { history.reconcile(entryID, after: nil); return }
        // This short follow-up must outlive cancellation of the original network operation.
        let task = Task { @MainActor in
            guard self.generation == requestGeneration, self.readKey() == key else {
                self.history.reconcile(entryID, after: nil, note: "账户配置已改变，停止自动核对。")
                return
            }
            do {
                let after = try await self.freshAccount(key: key)
                self.history.reconcile(entryID, after: after)
                if self.generation == requestGeneration {
                    self.account = after
                    self.accountError = nil
                    self.balanceAttempt = Date()
                }
            } catch {
                self.history.reconcile(entryID, after: nil, note: "免费余额核对暂不可用。")
                if self.generation == requestGeneration { self.accountError = "余额更新失败，显示的是上次查询结果。" }
            }
            if self.dailyUsage != nil { await self.refreshDailyUsage(force: true) }
        }
        await task.value
    }

    private func confirm(_ prompt: ChargePrompt) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                approval = continuation
                pendingCharge = prompt
            }
        } onCancel: {
            Task { @MainActor in
                if self.pendingCharge?.id == prompt.id { self.answerCharge(approved: false) }
            }
        }
    }

    func answerCharge(approved: Bool) {
        guard let continuation = approval else { return }
        approval = nil
        pendingCharge = nil
        if approved { continuation.resume() }
        else { continuation.resume(throwing: CancellationError()) }
    }

    /// Queue snapshots so a post-request check never reuses an earlier in-flight balance.
    private func freshAccount(key: String) async throws -> AccountBalance {
        let previous = accountTail
        let id = UUID()
        let task = Task { @MainActor in
            if let previous { _ = try? await previous.value }
            try Task.checkCancellation()
            let price = try await self.quote(Self.accountPath)
            guard price.amount == 0 else { throw AppError.message("余额接口已不是免费接口，已停止自动查询。") }
            if let last = self.accountLastSent {
                let remaining = 1.1 - Date().timeIntervalSince(last)
                if remaining > 0 { try await Task.sleep(for: .seconds(remaining)) }
            }
            try Task.checkCancellation()
            self.accountLastSent = Date()
            let response = try await self.transport.send(APIRequest(title: "查询余额", path: Self.accountPath, timeout: 10), apiKey: key)
            return try AccountBalance.decode(response)
        }
        accountTail = task
        accountTaskID = id
        defer { if accountTaskID == id { accountTail = nil; accountTaskID = nil } }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    func refreshBalance(force: Bool = false) async {
        guard !refreshing, !isWorking, let key = readKey() else { return }
        if let last = balanceAttempt, Date().timeIntervalSince(last) < (force ? 2 : 25) { return }
        refreshing = true
        balanceAttempt = Date()
        let requestGeneration = generation
        defer {
            refreshing = false
            if generation != requestGeneration, hasAPIKey { Task { await self.refreshBalance(force: true) } }
        }
        do {
            let latest = try await freshAccount(key: key)
            guard requestGeneration == generation, readKey() == key else { return }
            account = latest
            accountError = nil
        } catch is CancellationError { }
        catch {
            guard requestGeneration == generation else { return }
            accountError = (error as? AppError)?.localizedDescription ?? "余额更新失败，显示的是上次查询结果。"
        }
    }

    func refreshDailyUsage(force: Bool = false) async {
        guard !refreshingUsage, let key = readKey() else { return }
        if let last = usageAttempt, Date().timeIntervalSince(last) < (force ? 2 : 10) { return }
        refreshingUsage = true
        usageAttempt = Date()
        let requestGeneration = generation
        defer {
            refreshingUsage = false
            if generation != requestGeneration, hasAPIKey { Task { await self.refreshDailyUsage(force: true) } }
        }
        do {
            let price = try await quote(Self.usagePath)
            guard price.amount == 0 else { throw AppError.message("平台用量接口已不是免费接口，已停止自动查询。") }
            try Task.checkCancellation()
            guard generation == requestGeneration else { return }
            let response = try await transport.send(APIRequest(title: "查询平台当日用量", path: Self.usagePath, timeout: 12), apiKey: key)
            let latest = try DailyUsage.decode(response)
            guard requestGeneration == generation, readKey() == key else { return }
            dailyUsage = latest
            usageError = nil
        } catch is CancellationError { }
        catch {
            guard requestGeneration == generation else { return }
            usageError = (error as? AppError)?.localizedDescription ?? "平台用量更新失败，显示上次结果。"
        }
    }
}
