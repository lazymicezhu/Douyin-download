// Offline integration tests; every request and credential is synthetic.
// xcrun swiftc DouyinLite/Core/TikHub.swift DouyinLite/Core/APIClient.swift \
//   DouyinLite/KeyStore.swift DouyinLite/HistoryStore.swift DouyinLite/BillingCenter.swift tests/BillingTests.swift \
//   -module-cache-path /tmp/douyin-billing-cache -o /tmp/douyin-billing-tests
import Foundation

private actor BillingTransportStub: APITransporting {
    struct Call {
        let request: APIRequest
        let key: String?
    }
    static let quotePath = "/api/v1/tikhub/user/get_endpoint_info"
    static let accountPath = "/api/v1/tikhub/user/get_user_info"
    var calls: [Call] = []
    let contentCost: Any
    let accountCost: Any
    let contentStatus: Int
    let malformedQuote: Bool

    init(contentCost: Any = 0.001, accountCost: Any = 0,
         contentStatus: Int = 200, malformedQuote: Bool = false) {
        self.contentCost = contentCost
        self.accountCost = accountCost
        self.contentStatus = contentStatus
        self.malformedQuote = malformedQuote
    }

    func send(_ request: APIRequest, apiKey: String?) async throws -> APIResponse {
        calls.append(Call(request: request, key: apiKey))
        if request.path == Self.quotePath {
            let endpoint = request.query["endpoint"] ?? ""
            var data: [String: Any] = [
                "endpoint_uri": endpoint,
                "endpoint_cost": endpoint == Self.accountPath ? accountCost : contentCost,
                "allow_free_credit": true, "allow_discount": false
            ]
            if malformedQuote { data.removeValue(forKey: "endpoint_cost") }
            return try response(["code": 200, "data": data])
        }
        if request.path == Self.accountPath {
            return try response(["code": 200, "data": ["user_data": ["balance": "4.99", "free_credit": "0.05"]]])
        }
        return try response(["code": contentStatus, "data": ["items": [], "cursor": "next"]], status: contentStatus)
    }

    private func response(_ object: [String: Any], status: Int = 200) throws -> APIResponse {
        APIResponse(data: try JSONSerialization.data(withJSONObject: object), status: status)
    }

    func contentCalls() -> [Call] {
        calls.filter { $0.request.path != Self.quotePath && $0.request.path != Self.accountPath }
    }

    func accountCalls() -> [Call] { calls.filter { $0.request.path == Self.accountPath } }
}

@main
@MainActor
struct BillingTests {
    private enum Failure: LocalizedError {
        case check(String)
        var errorDescription: String? { if case let .check(message) = self { return message }; return nil }
    }

    private final class CredentialStub { var value: String? = "synthetic-test-key" }
    private static let path = "/api/v1/douyin/web/fetch_user_post_videos"
    private static var passed = 0

    private static func check(_ name: String, _ condition: Bool) throws {
        guard condition else { throw Failure.check(name) }
        passed += 1
        print("PASS: \(name)")
    }

    private static func request(cursor: String = "0") -> APIRequest {
        APIRequest(title: "测试作品，第 \(cursor) 页", path: path, query: ["max_cursor": cursor])
    }

    private static func prompt(_ billing: BillingCenter) async throws -> ChargePrompt {
        let deadline = Date().addingTimeInterval(3)
        while billing.pendingCharge == nil && Date() < deadline { try await Task.sleep(for: .milliseconds(1)) }
        guard let prompt = billing.pendingCharge else { throw Failure.check("confirmation was not presented") }
        return prompt
    }

    private static func cancelled(_ task: Task<Data, Error>) async throws {
        do {
            _ = try await task.value
            throw Failure.check("rejected/cancelled request unexpectedly completed")
        } catch is CancellationError { }
    }

    static func main() async throws {
        setbuf(stdout, nil)
        try check("test fixture targets current balance endpoint", BillingTransportStub.accountPath == BillingCenter.accountPath)
        try await confirmationAndPagination()
        try await rejectionAndCancellation()
        try await unknownPrices()
        try await balancePolicy()
        try await credentialsAndFailures()
        print("\(passed) offline billing checks passed. No network or real credentials used.")
    }

    private static func confirmationAndPagination() async throws {
        let transport = BillingTransportStub()
        let billing = BillingCenter(transport: transport, readKey: { "synthetic-test-key" })
        let first = Task { try await billing.perform(request()) }
        let firstPrompt = try await prompt(billing)
        try check("priced request waits for explicit approval", await transport.contentCalls().isEmpty)
        try check("confirmation identifies endpoint, action and amount",
                  firstPrompt.quote.path == path && firstPrompt.quote.amount == Decimal(string: "0.001")
                  && firstPrompt.title == request().title)
        let initialCalls = await transport.calls
        try check("price lookup is anonymous and uses the exact endpoint",
                  initialCalls.count == 1 && initialCalls[0].key == nil && initialCalls[0].request.query["endpoint"] == path)

        do {
            _ = try await billing.perform(request(cursor: "concurrent"))
            throw Failure.check("concurrent request unexpectedly ran")
        } catch is Failure { throw Failure.check("concurrent request unexpectedly ran") }
        catch { }
        try check("a second query cannot bypass an existing prompt", await transport.contentCalls().isEmpty)
        billing.answerCharge(approved: true)
        _ = try await first.value
        let firstCalls = await transport.contentCalls()
        try check("one approval dispatches exactly one authenticated request",
                  firstCalls.count == 1 && firstCalls[0].key == "synthetic-test-key")
        billing.answerCharge(approved: true)
        try check("repeated approval does not dispatch again", await transport.contentCalls().count == 1)

        let second = Task { try await billing.perform(request(cursor: "next")) }
        let secondPrompt = try await prompt(billing)
        try check("pagination gets a distinct approval", secondPrompt.id != firstPrompt.id && secondPrompt.title.contains("next"))
        try check("pagination does not dispatch before its approval", await transport.contentCalls().count == 1)
        billing.answerCharge(approved: true)
        _ = try await second.value
        let secondCalls = await transport.contentCalls()
        try check("approved page retains its own cursor", secondCalls.count == 2 && secondCalls[1].request.query["max_cursor"] == "next")

        let repeatTask = Task { try await billing.perform(request()) }
        let repeatPrompt = try await prompt(billing)
        let repeatCount = await transport.contentCalls().count
        try check("repeating a previously approved endpoint still needs consent", repeatPrompt.id != firstPrompt.id && repeatCount == 2)
        billing.answerCharge(approved: false)
        try await cancelled(repeatTask)
    }

    private static func rejectionAndCancellation() async throws {
        let transport = BillingTransportStub()
        let billing = BillingCenter(transport: transport, readKey: { "synthetic-test-key" })
        let rejected = Task { try await billing.perform(request()) }
        _ = try await prompt(billing)
        billing.answerCharge(approved: false)
        try await cancelled(rejected)
        try check("decline dispatches no paid call", await transport.contentCalls().isEmpty)
        try check("decline clears prompt and busy state", billing.pendingCharge == nil && !billing.isWorking)

        let cancelledTask = Task { try await billing.perform(request()) }
        _ = try await prompt(billing)
        cancelledTask.cancel()
        try await cancelled(cancelledTask)
        try check("task cancellation while prompting dispatches no paid call", await transport.contentCalls().isEmpty)
        try check("cancellation clears prompt and busy state", billing.pendingCharge == nil && !billing.isWorking)

        let race = Task { try await billing.perform(request()) }
        _ = try await prompt(billing)
        race.cancel()
        billing.answerCharge(approved: true)
        try await cancelled(race)
        try check("approval racing with cancellation still cannot charge", await transport.contentCalls().isEmpty)
    }

    private static func unknownPrices() async throws {
        for (name, cost, malformed) in [
            ("missing", 0.001 as Any, true),
            ("negative", -0.001 as Any, false),
            ("boolean", true as Any, false),
            ("nonnumeric", "unknown" as Any, false)
        ] {
            let transport = BillingTransportStub(contentCost: cost, malformedQuote: malformed)
            let billing = BillingCenter(transport: transport, readKey: { "synthetic-test-key" })
            do {
                _ = try await billing.perform(request())
                throw Failure.check("\(name) price unexpectedly accepted")
            } catch is Failure { throw Failure.check("\(name) price unexpectedly accepted") }
            catch { }
            try check("\(name) price blocks all content requests", await transport.contentCalls().isEmpty)
            try check("\(name) price leaves no pending approval", billing.pendingCharge == nil && !billing.isWorking)
        }
    }

    private static func balancePolicy() async throws {
        let free = BillingTransportStub()
        let freeBilling = BillingCenter(transport: free, readKey: { "synthetic-test-key" })
        await freeBilling.refreshBalance(force: true)
        let freeCalls = await free.calls
        try check("free balance refresh first verifies its current price",
                  freeCalls.count == 2 && freeCalls[0].request.path == BillingTransportStub.quotePath
                  && freeCalls[0].request.query["endpoint"] == BillingCenter.accountPath
                  && freeCalls[0].key == nil && freeCalls[1].request.path == BillingCenter.accountPath)
        try check("free balance result is parsed", freeBilling.account?.balance == Decimal(string: "4.99") && freeBilling.account?.freeCredit == Decimal(string: "0.05"))
        await freeBilling.refreshBalance(force: true)
        try check("rapid forced refreshes are throttled", await free.accountCalls().count == 1)

        let paid = BillingTransportStub(accountCost: 0.001)
        let paidBilling = BillingCenter(transport: paid, readKey: { "synthetic-test-key" })
        await paidBilling.refreshBalance(force: true)
        try check("paid balance endpoint is never queried automatically", await paid.accountCalls().isEmpty)
        try check("paid balance endpoint shows a pause reason", paidBilling.account == nil && paidBilling.accountError != nil && paidBilling.pendingCharge == nil)

        let unknown = BillingTransportStub(malformedQuote: true)
        let unknownBilling = BillingCenter(transport: unknown, readKey: { "synthetic-test-key" })
        await unknownBilling.refreshBalance(force: true)
        try check("unknown balance price blocks automatic query", await unknown.accountCalls().isEmpty && unknownBilling.accountError != nil)

        let automatic = BillingTransportStub(accountCost: 0.001)
        let automaticBilling = BillingCenter(transport: automatic, readKey: { "synthetic-test-key" })
        let task = Task { try await automaticBilling.perform(request()) }
        _ = try await prompt(automaticBilling)
        automaticBilling.answerCharge(approved: true)
        _ = try await task.value
        for _ in 0..<20 { await Task.yield() }
        try check("post-query balance refresh also refuses a paid balance endpoint", await automatic.accountCalls().isEmpty)
    }

    private static func credentialsAndFailures() async throws {
        let transport = BillingTransportStub()
        let missing = BillingCenter(transport: transport, readKey: { nil })
        do {
            _ = try await missing.perform(request())
            throw Failure.check("missing credentials unexpectedly accepted")
        } catch is Failure { throw Failure.check("missing credentials unexpectedly accepted") }
        catch { }
        await missing.refreshBalance(force: true)
        try check("missing credentials cause no transport calls", await transport.calls.isEmpty)

        let key = CredentialStub()
        let changing = BillingCenter(transport: transport, readKey: { key.value })
        let task = Task { try await changing.perform(request()) }
        _ = try await prompt(changing)
        key.value = nil
        changing.credentialsChanged()
        try await cancelled(task)
        try check("removing credentials invalidates pending approval", await transport.contentCalls().isEmpty && !changing.hasAPIKey)

        let failed = BillingTransportStub(contentStatus: 500)
        let failedBilling = BillingCenter(transport: failed, readKey: { "synthetic-test-key" })
        let failedTask = Task { try await failedBilling.perform(request()) }
        _ = try await prompt(failedBilling)
        failedBilling.answerCharge(approved: true)
        do {
            _ = try await failedTask.value
            throw Failure.check("HTTP failure unexpectedly accepted")
        } catch is Failure { throw Failure.check("HTTP failure unexpectedly accepted") }
        catch { }
        for _ in 0..<20 { await Task.yield() }
        try check("failed paid requests are never retried automatically", await failed.contentCalls().count == 1 && !failedBilling.isWorking)
    }
}
