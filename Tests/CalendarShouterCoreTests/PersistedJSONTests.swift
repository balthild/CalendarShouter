import Foundation
import Testing

@testable import CalendarShouterCore

private func makeDefaults() -> UserDefaults {
	let suiteName = "CalendarShouterTests.\(UUID().uuidString)"
	let defaults = UserDefaults(suiteName: suiteName)!
	defaults.removePersistentDomain(forName: suiteName)
	return defaults
}

private struct Note: Codable, Equatable {
	var title: String
	var count: Int
}

@Suite("PersistedJSON")
struct PersistedJSONTests {
	@Test("A value survives a round trip")
	func roundTrip() {
		let defaults = makeDefaults()
		PersistedJSON.set(["a", "b"], forKey: "key", in: defaults)
		#expect(PersistedJSON.value([String].self, forKey: "key", in: defaults) == ["a", "b"])
	}

	@Test("A struct is stored as a dictionary rather than a blob")
	func storesAStructAsADictionary() {
		let defaults = makeDefaults()
		let note = Note(title: "Standup", count: 2)

		PersistedJSON.set(note, forKey: "key", in: defaults)

		#expect(defaults.dictionary(forKey: "key") != nil)
		#expect(defaults.data(forKey: "key") == nil)
		#expect(PersistedJSON.value(Note.self, forKey: "key", in: defaults) == note)
	}

	@Test("A value containing a null stays as text, the only shape UserDefaults accepts")
	func nullKeepsTheValueAsText() {
		// `UserDefaults` aborts the process on `NSNull` rather than reporting an error, so a value
		// containing one must not be converted to a property-list object.
		let defaults = makeDefaults()
		let sparse: [String: Int?] = ["present": 1, "absent": nil]

		PersistedJSON.set(sparse, forKey: "key", in: defaults)

		#expect(defaults.data(forKey: "key") != nil)
		#expect(PersistedJSON.value([String: Int?].self, forKey: "key", in: defaults) == sparse)
	}

	@Test("Text written by an earlier version still decodes")
	func legacyTextStillDecodes() throws {
		let defaults = makeDefaults()
		defaults.set(try JSONEncoder().encode(["a", "b"]), forKey: "key")

		#expect(PersistedJSON.value([String].self, forKey: "key", in: defaults) == ["a", "b"])
	}

	@Test("A key that was never written reads as absent, without quarantining anything")
	func absentKey() {
		let defaults = makeDefaults()
		#expect(PersistedJSON.value([String].self, forKey: "key", in: defaults) == nil)
		#expect(defaults.data(forKey: PersistedJSON.quarantineKey(for: "key")) == nil)
	}

	@Test("A value that no longer decodes is kept aside instead of being lost")
	func unreadableValueIsQuarantined() {
		let defaults = makeDefaults()
		let stored = Data(#"[{"id":"a"}]"#.utf8)
		defaults.set(stored, forKey: "key")

		#expect(PersistedJSON.value([Int].self, forKey: "key", in: defaults) == nil)
		#expect(defaults.data(forKey: "key") == stored)
		#expect(defaults.data(forKey: PersistedJSON.quarantineKey(for: "key")) == stored)
	}

	@Test("Quarantining happens once, so a later write is not undone")
	func quarantineDoesNotOverwriteItself() {
		let defaults = makeDefaults()
		defaults.set(Data("first".utf8), forKey: "key")
		_ = PersistedJSON.value([Int].self, forKey: "key", in: defaults)

		// A second read, of a value that still will not decode, must leave the copy alone.
		defaults.set(Data("second".utf8), forKey: "key")
		_ = PersistedJSON.value([Int].self, forKey: "key", in: defaults)

		#expect(defaults.data(forKey: PersistedJSON.quarantineKey(for: "key")) == Data("first".utf8))
	}
}

@Suite("SettingsStore persistence")
@MainActor
struct SettingsStorePersistenceTests {
	@Test("An account list written by an earlier version still decodes")
	func accountListIsForwardCompatible() throws {
		let defaults = makeDefaults()
		let account = CanvasAccount(
			id: "canvas.example.edu#7",
			domain: "canvas.example.edu",
			baseURL: URL(string: "https://canvas.example.edu")!,
			userID: "7",
			userName: "Student",
			addedAt: Date(timeIntervalSinceReferenceDate: 0)
		)
		let encoder = JSONEncoder()
		var objects =
			try JSONSerialization.jsonObject(
				with: encoder.encode([account])
			) as! [[String: Any]]
		// A field a later version might add. Unknown keys are ignored, which is what keeps
		// a downgrade from destroying the accounts.
		objects[0]["unrecognisedField"] = "x"
		defaults.set(try JSONSerialization.data(withJSONObject: objects), forKey: "canvasAccounts")

		let store = SettingsStore(defaults: defaults)

		#expect(store.canvasAccounts.map(\.id) == ["canvas.example.edu#7"])
	}

	@Test("A stored account list that will not decode is kept aside, not deleted")
	func unreadableAccountListIsKeptAside() throws {
		let defaults = makeDefaults()
		let account = CanvasAccount(
			id: "canvas.example.edu#7",
			domain: "canvas.example.edu",
			baseURL: URL(string: "https://canvas.example.edu")!,
			userID: "7",
			userName: "Student",
			addedAt: Date(timeIntervalSinceReferenceDate: 0)
		)
		var objects =
			try JSONSerialization.jsonObject(
				with: JSONEncoder().encode([account])
			) as! [[String: Any]]
		// Stands in for the field a future version makes mandatory.
		objects[0].removeValue(forKey: "userName")
		let stored = try JSONSerialization.data(withJSONObject: objects)
		defaults.set(stored, forKey: "canvasAccounts")

		let store = SettingsStore(defaults: defaults)

		#expect(store.canvasAccounts.isEmpty)
		// The whole list is decoded at once, so one bad record used to take every account
		// with it; the original bytes must at least survive.
		#expect(defaults.data(forKey: "canvasAccounts") == stored)
		#expect(defaults.data(forKey: "canvasAccounts.unreadable") == stored)
	}
}
