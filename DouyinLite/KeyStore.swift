import Foundation
import Security

enum KeyStore {
    private static let service = "DouyinLite.TikHub"
    private static let account = "api-key"
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    static func read() -> String? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ key: String) throws {
        let value: [String: Any] = [kSecValueData as String: Data(key.utf8),
                                  kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        var status = SecItemUpdate(query as CFDictionary, value as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(value, uniquingKeysWith: { _, new in new }) as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw error(for: status, action: "保存") }
        guard read() == key else {
            throw AppError.message("密钥写入后未能读回。请保持手机解锁并重试；若重新签名过，请检查签名的应用标识和钥匙串权限。")
        }
    }

    static func remove() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw error(for: status, action: "移除")
        }
    }

    private static func error(for status: OSStatus, action: String) -> AppError {
        switch status {
        case errSecMissingEntitlement:
            return .message("当前签名缺少钥匙串权限（\(status)）。请在全能签重新签名时检查应用标识及钥匙串访问权限；这不是配置文件格式问题。")
        case errSecInteractionNotAllowed, errSecNotAvailable:
            return .message("系统暂不允许\(action)密钥，请解锁手机并保持应用在前台后重试。（钥匙串错误 \(status)）")
        default:
            return .message("无法\(action)密钥，系统钥匙串返回错误 \(status)。请保留此错误码以便定位。")
        }
    }
}
