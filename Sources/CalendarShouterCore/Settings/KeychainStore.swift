import Foundation
import Security

/// Somewhere to keep the few secrets the app has.
///
/// A protocol so that the service above it can be exercised without touching the real
/// keychain, which prompts on rebuilds of an unsigned build.
public protocol SecretStore: Sendable {
	func data(for key: String) throws -> Data?
	func set(_ data: Data, for key: String) throws
	func removeValue(for key: String) throws
}

public enum SecretStoreError: Error {
	case corruptData
}

extension SecretStore {
	public func value<T: Decodable>(_ type: T.Type, for key: String) throws -> T? {
		guard let data = try data(for: key) else { return nil }
		do {
			return try JSONDecoder().decode(type, from: data)
		} catch {
			throw SecretStoreError.corruptData
		}
	}

	public func setValue<T: Encodable>(_ value: T, for key: String) throws {
		try set(JSONEncoder().encode(value), for: key)
	}
}

/// The app's own keychain items.
///
/// Two kinds of secret live here, both per Canvas account: the OAuth tokens, and the client
/// credentials Canvas handed out for that account's domain. Neither belongs in a
/// preferences plist, where anything running as the user could read them.
///
/// Items are created with `kSecAttrAccessibleAfterFirstUnlock` so the rolling refresh can
/// still run while the screen is locked, which is exactly the case a menu-bar app has to
/// cope with.
public struct KeychainStore: SecretStore {
	public enum Failure: Error, CustomStringConvertible {
		case unhandled(OSStatus)

		public var description: String {
			switch self {
			case .unhandled(let status):
				return "Keychain error \(status)"
			}
		}
	}

	private let service: String

	public init(service: String = "com.balthild.CalendarShouter") {
		self.service = service
	}

	private func baseQuery(for key: String) -> [String: Any] {
		[
			kSecClass as String: kSecClassGenericPassword,
			kSecAttrService as String: service,
			kSecAttrAccount as String: key,
		]
	}

	public func data(for key: String) throws -> Data? {
		var query = baseQuery(for: key)
		query[kSecReturnData as String] = true
		query[kSecMatchLimit as String] = kSecMatchLimitOne

		var result: CFTypeRef?
		switch SecItemCopyMatching(query as CFDictionary, &result) {
		case errSecSuccess:
			return result as? Data
		case errSecItemNotFound:
			return nil
		case let status:
			throw Failure.unhandled(status)
		}
	}

	public func set(_ data: Data, for key: String) throws {
		let attributes: [String: Any] = [
			kSecValueData as String: data,
			kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
		]
		let query = baseQuery(for: key)

		switch SecItemUpdate(query as CFDictionary, attributes as CFDictionary) {
		case errSecSuccess:
			return
		case errSecItemNotFound:
			let added = query.merging(attributes) { _, new in new }
			let status = SecItemAdd(added as CFDictionary, nil)
			guard status == errSecSuccess else { throw Failure.unhandled(status) }
		case let status:
			throw Failure.unhandled(status)
		}
	}

	public func removeValue(for key: String) throws {
		switch SecItemDelete(baseQuery(for: key) as CFDictionary) {
		case errSecSuccess, errSecItemNotFound:
			return
		case let status:
			throw Failure.unhandled(status)
		}
	}
}

extension KeychainStore {
	public enum Item {
		/// The account's access and refresh tokens.
		public static func tokens(accountID: String) -> String { "canvas.token.\(accountID)" }
		/// The OAuth client credentials issued for the account's domain.
		public static func client(accountID: String) -> String { "canvas.client.\(accountID)" }
	}
}
