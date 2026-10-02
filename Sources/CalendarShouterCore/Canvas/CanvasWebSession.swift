import Foundation
import WebKit

/// The browser session an account's Canvas sign-in runs in.
///
/// Each account gets its own persistent `WKWebsiteDataStore`, so that signing in to one
/// account can neither reuse another's session nor leave one behind for the next account.
public enum CanvasWebSession {
	/// The store a sign-in should run in.
	@MainActor
	public static func store(forIdentifier identifier: UUID) -> WKWebsiteDataStore {
		WKWebsiteDataStore(forIdentifier: identifier)
	}
}

/// The fallback for an account that was stored before it had a session of its own.
///
/// A *computed* property: each account has to be handed a different identifier, or every
/// such account would end up sharing one browser session — the very thing per-account
/// sessions exist to prevent.
public enum NewWebSessionIdentifier: FallbackProvider {
	public static var fallbackValue: UUID { UUID() }
}

/// Removes the browser sessions that accounts own.
///
/// Injected into `CanvasService` for the same reason `SecretStore` is: the account's
/// sign-in state is cleaned up with the account, and tests must not touch real WebKit data.
@MainActor
public protocol CanvasWebSessionStoring: Sendable {
	/// Deletes the session an account signs in with.
	func discard(identifier: UUID)
	/// Deletes every stored session that no account claims.
	func discardUnclaimed(keeping identifiers: Set<UUID>)
}

/// The sessions as WebKit keeps them.
///
/// Every profile store the app has ever created belongs to a Canvas account — the sign-in
/// sheet is the only thing that creates one — which is what lets `discardUnclaimed` tell an
/// orphan from a session still in use.
public struct SystemCanvasWebSessions: CanvasWebSessionStoring {
	public init() {}

	public func discard(identifier: UUID) {
		Task { @MainActor in
			try? await WKWebsiteDataStore.remove(forIdentifier: identifier)
		}
	}

	public func discardUnclaimed(keeping identifiers: Set<UUID>) {
		Task { @MainActor in
			let stored = await withCheckedContinuation { continuation in
				WKWebsiteDataStore.fetchAllDataStoreIdentifiers { continuation.resume(returning: $0) }
			}
			// The default store carries no identifier, so it is never a candidate.
			for identifier in stored where !identifiers.contains(identifier) {
				try? await WKWebsiteDataStore.remove(forIdentifier: identifier)
			}
		}
	}
}
