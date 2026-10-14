import XCTest
import Security
@testable import MeetingCore

private final class IsolatedKeychainBackend: CredentialKeychainBackend, @unchecked Sendable {
    var accounts: [String: Data] = [:]
    var services: [String] = []
    var status: Int32 = errSecSuccess
    func create(service: String, account: String, secret: Data) -> Int32 {
        services.append(service)
        if status == errSecSuccess { accounts[account] = secret }
        return status
    }
    func read(service: String, account: String) -> (Int32, Data?) {
        services.append(service)
        guard status == errSecSuccess else { return (status, nil) }
        return accounts[account].map { (errSecSuccess, $0) } ?? (errSecItemNotFound, nil)
    }
    func delete(service: String, account: String) -> Int32 {
        services.append(service)
        guard status == errSecSuccess else { return status }
        return accounts.removeValue(forKey: account) == nil ? errSecItemNotFound : errSecSuccess
    }
}

final class CredentialStoreTests: XCTestCase {
    func testOpaqueReferencesAccessOnlyExactOwnServiceItems() throws {
        let backend = IsolatedKeychainBackend()
        let store = KeychainCredentialStore(backend: backend)
        let first = try store.create(Data([1, 2]))
        let second = try store.create(Data([3]))
        XCTAssertNotNil(UUID(uuidString: first))
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(try store.read(reference: first), Data([1, 2]))
        try store.delete(reference: first)
        XCTAssertNil(try store.read(reference: first))
        XCTAssertEqual(try store.read(reference: second), Data([3]))
        try store.delete(reference: first)
        XCTAssertEqual(Set(backend.services), ["com.hansluo.meetingmac"])
    }
    func testMalformedReferencesNeverReachKeychainBackend() {
        let backend = IsolatedKeychainBackend()
        let store = KeychainCredentialStore(backend: backend)
        for reference in ["", "other-app-key", "*", "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"] {
            XCTAssertThrowsError(try store.read(reference: reference)) {
                XCTAssertEqual($0 as? CredentialStoreError, CredentialStoreError(status: errSecParam))
            }
            XCTAssertThrowsError(try store.delete(reference: reference))
        }
        XCTAssertTrue(backend.services.isEmpty)
    }
    func testErrorsExposeStatusOnly() {
        let backend = IsolatedKeychainBackend()
        backend.status = errSecAuthFailed
        let store = KeychainCredentialStore(backend: backend)
        XCTAssertThrowsError(try store.create(Data("SECRET".utf8))) {
            XCTAssertEqual($0 as? CredentialStoreError, CredentialStoreError(status: errSecAuthFailed))
            XCTAssertFalse(String(describing: $0).contains("SECRET"))
        }
        XCTAssertThrowsError(try store.read(reference: UUID().uuidString)) {
            XCTAssertEqual($0 as? CredentialStoreError, CredentialStoreError(status: errSecAuthFailed))
        }
        XCTAssertThrowsError(try store.delete(reference: UUID().uuidString))
    }
    func testRealSecurityRandomOwnItemRoundTripWithoutInteractiveAuthentication() throws {
        let store = KeychainCredentialStore()
        let secret = Data(UUID().uuidString.utf8)
        let reference: String
        do { reference = try store.create(secret) }
        catch let error as CredentialStoreError {
            if [errSecNotAvailable, errSecInteractionNotAllowed, errSecAuthFailed,
                errSecMissingEntitlement, errSecUserCanceled].contains(error.status) {
                throw XCTSkip("Noninteractive Keychain unavailable: status \(error.status)")
            }
            throw error
        }
        do {
            let actual = try store.read(reference: reference)
            XCTAssertEqual(actual, secret)
        } catch {
            try store.delete(reference: reference)
            throw error
        }
        try store.delete(reference: reference)
        XCTAssertNil(try store.read(reference: reference))
    }
}
