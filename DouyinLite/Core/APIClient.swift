import Foundation
import CoreFoundation

struct APIRequest {
    var title: String
    var path: String
    var method: String = "GET"
    var query: [String: String] = [:]
    var body: [String: Any]? = nil
    var timeout: TimeInterval = 60
}

struct APIResponse {
    let data: Data
    let status: Int
}

protocol APITransporting {
    func send(_ request: APIRequest, apiKey: String?) async throws -> APIResponse
}

struct APITransport: APITransporting {
    func send(_ request: APIRequest, apiKey: String?) async throws -> APIResponse {
        guard request.path.hasPrefix("/api/v1/"), !request.path.contains(".."),
              !request.path.contains("?"), !request.path.contains("#"),
              ["GET", "POST"].contains(request.method) else {
            throw AppError.message("接口配置无效。")
        }
        var components = URLComponents()
        components.scheme = "https"
        components.host = "api.tikhub.io"
        components.path = request.path
        components.queryItems = request.query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = components.url else { throw AppError.message("无法创建请求。") }
        var message = URLRequest(url: url)
        message.httpMethod = request.method
        message.timeoutInterval = min(60, max(5, request.timeout))
        message.setValue("application/json", forHTTPHeaderField: "Accept")
        message.setValue("DouyinLite/2.1 (iOS)", forHTTPHeaderField: "User-Agent")
        if let apiKey {
            message.setValue("Bearer \(try Configuration.validatedKey(apiKey))", forHTTPHeaderField: "Authorization")
        }
        if let body = request.body {
            message.httpBody = try JSONSerialization.data(withJSONObject: body)
            message.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForResource = message.timeoutInterval + 15
        let session = URLSession(configuration: configuration, delegate: APIHostPolicy(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: message)
        guard let response = response as? HTTPURLResponse else { throw AppError.message("服务返回异常。") }
        return APIResponse(data: data, status: response.statusCode)
    }
}

private final class APIHostPolicy: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        // A redirect could change both the billed endpoint and the credential recipient.
        completionHandler(nil)
    }
}

enum APIJSON {
    static func object(_ response: APIResponse) throws -> [String: Any] {
        guard (200...299).contains(response.status) else { throw TikHubResponse.error(for: response.status) }
        guard let json = try JSONSerialization.jsonObject(with: response.data) as? [String: Any] else {
            throw AppError.message("服务返回了无法读取的数据。")
        }
        if let code = (json["code"] as? NSNumber)?.intValue, code != 200 && code != 0 {
            throw TikHubResponse.error(for: code)
        }
        return json
    }
}

struct EndpointQuote: Equatable {
    let path: String
    let amount: Decimal
    let allowsFreeCredit: Bool
    let allowsDiscount: Bool
    let obtainedAt: Date

    static func decode(_ response: APIResponse, path: String) throws -> EndpointQuote {
        let object = try APIJSON.object(response)
        guard let data = object["data"] as? [String: Any], data["endpoint_uri"] as? String == path,
              let number = data["endpoint_cost"] as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite,
              let amount = Decimal(string: number.stringValue, locale: Locale(identifier: "en_US_POSIX")), amount >= 0 else {
            throw AppError.message("无法确认本次价格，已停止请求。请稍后重试。")
        }
        return EndpointQuote(path: path, amount: amount,
                             allowsFreeCredit: data["allow_free_credit"] as? Bool ?? false,
                             allowsDiscount: data["allow_discount"] as? Bool ?? false,
                             obtainedAt: Date())
    }
}

struct AccountBalance: Equatable {
    let balance: Decimal
    let freeCredit: Decimal?
    let updatedAt: Date

    static func decode(_ response: APIResponse) throws -> AccountBalance {
        let object = try APIJSON.object(response)
        let payload = object["data"] as? [String: Any] ?? object
        guard let user = payload["user_data"] as? [String: Any], let balance = decimal(user["balance"]) else {
            throw AppError.message("暂时无法读取余额。")
        }
        return AccountBalance(balance: balance, freeCredit: decimal(user["free_credit"]), updatedAt: Date())
    }

    static func decimal(_ value: Any?) -> Decimal? {
        let string: String
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite { string = number.stringValue }
        else if let text = value as? String { string = text }
        else { return nil }
        guard let amount = Decimal(string: string, locale: Locale(identifier: "en_US_POSIX")), !amount.isNaN else { return nil }
        return amount
    }
}

enum Money {
    static func usd(_ amount: Decimal) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 8
        formatter.numberStyle = .decimal
        return "$" + (formatter.string(from: NSDecimalNumber(decimal: amount)) ?? "—")
    }
}


struct DailyUsage: Equatable {
    let date: String
    let normalUsed: Decimal
    let giftUsed: Decimal
    var totalUsed: Decimal { normalUsed + giftUsed }
    let paidRequests: Int?
    let updatedAt: Date

    static func decode(_ response: APIResponse) throws -> DailyUsage {
        let object = try APIJSON.object(response)
        guard let data = object["data"] as? [String: Any],
              let date = data["date"] as? String, !date.isEmpty,
              let normal = AccountBalance.decimal(data["balance_usage"]), normal >= 0,
              let gift = AccountBalance.decimal(data["free_credit_usage"]), gift >= 0 else {
            throw AppError.message("平台暂未返回可读取的每日用量。")
        }
        return DailyUsage(date: String(date.prefix(40)), normalUsed: normal, giftUsed: gift,
                          paidRequests: (data["paid_request_per_day"] as? NSNumber)?.intValue, updatedAt: Date())
    }
}
