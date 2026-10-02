import Foundation
import Testing
import WebKit

@testable import CalendarShouterCore

@Suite("Canvas web sessions")
@MainActor
struct CanvasWebSessionTests {
	@Test("An account's own store is the one it names")
	func storeMatchesItsIdentifier() async {
		let identifier = UUID()
		let store = CanvasWebSession.store(forIdentifier: identifier)

		#expect(store.identifier == identifier)
		#expect(store.isPersistent)

		await withCheckedContinuation { continuation in
			WKWebsiteDataStore.remove(forIdentifier: identifier) { _ in
				continuation.resume()
			}
		}
	}
}

@Suite("Canvas account session migration")
struct CanvasAccountSessionMigrationTests {
	/// What an earlier version wrote: no `storeIdentifier` key at all.
	private let legacyAccount = Data(
		#"{"id":"a","domain":"d","baseURL":"https://d","userID":"1","userName":"S","addedAt":0}"#.utf8
	)

	@Test("An account stored before the field existed still decodes")
	func legacyAccountDecodes() throws {
		// The failure `@Fallback` exists to prevent: without it the decode throws, and the
		// caller turns the error into an empty account list.
		let decoded = try JSONDecoder().decode(CanvasAccount.self, from: legacyAccount)

		#expect(decoded.id == "a")
		#expect(decoded.userName == "S")
	}

	@Test("Two accounts stored before the field existed do not share a session")
	func legacyAccountsGetDistinctSessions() throws {
		// The fallback must be computed, not a constant: a `static let` would hand every
		// account the same identifier and put them back to sharing one browser session.
		var second = try JSONSerialization.jsonObject(with: legacyAccount) as! [String: Any]
		second["id"] = "b"
		let twoAccounts = try JSONSerialization.data(withJSONObject: [
			try JSONSerialization.jsonObject(with: legacyAccount), second,
		])

		let decoded = try JSONDecoder().decode([CanvasAccount].self, from: twoAccounts)

		#expect(decoded.count == 2)
		#expect(decoded[0].storeIdentifier != decoded[1].storeIdentifier)
	}

	@Test("A list is not lost to one account written before the field existed")
	func legacyAccountListDecodes() throws {
		// The shape the app actually stores, where one unreadable record would otherwise
		// take every other account with it.
		let newer = CanvasAccount(
			id: "b",
			domain: "d",
			baseURL: URL(string: "https://d")!,
			userID: "1",
			userName: "S",
			addedAt: Date(timeIntervalSinceReferenceDate: 0),
			storeIdentifier: UUID()
		)
		let stored = try JSONEncoder().encode([newer])

		var objects = try JSONSerialization.jsonObject(with: stored) as! [[String: Any]]
		var legacy = objects[0]
		legacy["id"] = "a"
		legacy.removeValue(forKey: "storeIdentifier")
		objects.append(legacy)

		let decoded = try JSONDecoder().decode(
			[CanvasAccount].self,
			from: try JSONSerialization.data(withJSONObject: objects)
		)

		#expect(decoded.map(\.id) == ["b", "a"])
		#expect(decoded[1].storeIdentifier != decoded[0].storeIdentifier)
	}

	@Test("A recorded session survives a round trip")
	func identifierRoundTrips() throws {
		let identifier = UUID()
		let account = CanvasAccount(
			id: "a",
			domain: "d",
			baseURL: URL(string: "https://d")!,
			userID: "1",
			userName: "S",
			addedAt: Date(timeIntervalSinceReferenceDate: 0),
			storeIdentifier: identifier
		)

		let data = try JSONEncoder().encode(account)
		let decoded = try JSONDecoder().decode(CanvasAccount.self, from: data)

		#expect(decoded.storeIdentifier == identifier)
	}

	@Test("An unreadable session falls back instead of failing the whole account")
	func corruptIdentifierFallsBack() throws {
		let account = CanvasAccount(
			id: "a",
			domain: "d",
			baseURL: URL(string: "https://d")!,
			userID: "1",
			userName: "S",
			addedAt: Date(timeIntervalSinceReferenceDate: 0),
			storeIdentifier: UUID()
		)
		var object =
			try JSONSerialization.jsonObject(with: JSONEncoder().encode(account)) as! [String: Any]
		object["storeIdentifier"] = "not-a-uuid"

		let decoded = try JSONDecoder().decode(
			CanvasAccount.self,
			from: try JSONSerialization.data(withJSONObject: object)
		)

		// A fresh session rather than a failure: the account itself is still good.
		#expect(decoded.userName == "S")
		#expect(decoded.storeIdentifier != account.storeIdentifier)
	}
}
