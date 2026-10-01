import Foundation

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

/// Names for the secrets the app keeps.
///
/// The secrets live in the keychain, but the app never touches it directly: the helper does
/// (see `KeychainHelperClient`). All this names is the keys, so that the caller and the
/// helper agree on them.
public enum SecretKey {}

extension SecretKey {
	public enum Item {
		/// The account's access and refresh tokens.
		public static func tokens(accountID: String) -> String { "canvas.token.\(accountID)" }
		/// The OAuth client credentials issued for the account's domain.
		public static func client(accountID: String) -> String { "canvas.client.\(accountID)" }
	}
}
