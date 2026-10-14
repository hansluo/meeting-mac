import Foundation
import Security
import LocalAuthentication

/// Operations are synchronous so configuration transactions cannot interleave at suspension points.
public protocol CredentialStore: Sendable {
    func create(_ secret: Data) throws -> String
    func read(reference: String) throws -> Data?
    func delete(reference: String) throws
}

/// Stable OSStatus only. Never includes credential bytes or platform error descriptions.
public struct CredentialStoreError: Error, Sendable, Equatable {
    public let status: Int32
    public init(status: Int32) { self.status = status }
}

protocol CredentialKeychainBackend: Sendable {
    func create(service: String, account: String, secret: Data) -> Int32
    func read(service: String, account: String) -> (Int32, Data?)
    func delete(service: String, account: String) -> Int32
}

/// Exact UUID-account access within this application's service. No enumeration API.
public struct KeychainCredentialStore: CredentialStore {
    public static let service = "com.hansluo.meetingmac"
    private let backend: any CredentialKeychainBackend
    public init() { backend = SecurityCredentialBackend() }
    init(backend: any CredentialKeychainBackend) { self.backend = backend }

    public func create(_ secret: Data) throws -> String {
        let reference = UUID().uuidString
        let status = backend.create(service: Self.service, account: reference, secret: secret)
        guard status == errSecSuccess else { throw CredentialStoreError(status: status) }
        return reference
    }
    public func read(reference: String) throws -> Data? {
        try validate(reference)
        let (status, data) = backend.read(service: Self.service, account: reference)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw CredentialStoreError(status: status) }
        guard let data else { throw CredentialStoreError(status: errSecDecode) }
        return data
    }
    public func delete(reference: String) throws {
        try validate(reference)
        let status = backend.delete(service: Self.service, account: reference)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CredentialStoreError(status: status)
        }
    }
    private func validate(_ reference: String) throws {
        guard let uuid = UUID(uuidString: reference), uuid.uuidString == reference else {
            throw CredentialStoreError(status: errSecParam)
        }
    }
}

private struct SecurityCredentialBackend: CredentialKeychainBackend {
    private func query(service: String, account: String) -> [String: Any] {
        let context = LAContext()
        context.interactionNotAllowed = true
        return [kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service, kSecAttrAccount as String: account,
                kSecUseAuthenticationContext as String: context]
    }
    func create(service: String, account: String, secret: Data) -> Int32 {
        var attributes = query(service: service, account: account)
        attributes[kSecValueData as String] = secret
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        return SecItemAdd(attributes as CFDictionary, nil)
    }
    func read(service: String, account: String) -> (Int32, Data?) {
        var attributes = query(service: service, account: account)
        attributes[kSecReturnData as String] = true
        attributes[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(attributes as CFDictionary, &result)
        return (status, result as? Data)
    }
    func delete(service: String, account: String) -> Int32 {
        SecItemDelete(query(service: service, account: account) as CFDictionary)
    }
}
