import Foundation
import Testing

@testable import CalendarShouterCore

private enum FalseFlag: FallbackProvider {
	static var fallbackValue: Bool { false }
}

private enum EmptyTitle: FallbackProvider {
	static var fallbackValue: String { "" }
}

/// A fallback that is not `nil`, which is the only kind that can tell an absent key from an
/// explicit `null` — a `nil` fallback answers both the same way, which is how the wrapper
/// got the two confused without any test noticing.
private enum MissingNote: FallbackProvider {
	static var fallbackValue: String? { "missing" }
}

/// Hands out a fresh value every time, the way `NewWebSessionIdentifier` does.
private enum FreshIdentifier: FallbackProvider {
	static var fallbackValue: UUID { UUID() }
}

private struct Model: Codable {
	@Fallback<FalseFlag> var flag: Bool
	@Fallback<EmptyTitle> var title: String
	@Fallback<MissingNote> var note: String?
	@Fallback<FreshIdentifier> var identifier: UUID
}

@Suite("Fallback")
struct FallbackTests {
	@Test("A missing key takes the provider's value")
	func missingKeyUsesFallback() throws {
		let model = try JSONDecoder().decode(Model.self, from: Data("{}".utf8))

		#expect(model.flag == false)
		#expect(model.title == "")
		#expect(model.note == "missing")
	}

	@Test("An unreadable value takes the fallback without failing the decode")
	func unreadableValueUsesFallback() throws {
		// The whole point of the wrapper: a stored value of the wrong type costs that one
		// field, not the type that contains it.
		let json = #"{"flag":"yes","title":123,"note":[1,2]}"#

		let model = try JSONDecoder().decode(Model.self, from: Data(json.utf8))

		#expect(model.flag == false)
		#expect(model.title == "")
		// Unreadable is not the same as null: this one still falls back.
		#expect(model.note == "missing")
	}

	@Test("An explicit null decodes as nil rather than taking the fallback")
	func nullIsNotAMissingKey() throws {
		// The distinction `decodeIfPresent` cannot make: it reports an explicit null as an
		// absent key, which replaced a stored null with the provider's value.
		let json = #"{"note":null}"#

		let model = try JSONDecoder().decode(Model.self, from: Data(json.utf8))

		#expect(model.note == nil)
	}

	@Test("An explicit null still takes the fallback where there is no null to hold")
	func nullUsesFallbackForNonOptionalValues() throws {
		// Only an optional-valued wrapper can decode a null as a value. A `Bool` has no null
		// to hold, so the fallback is still the only answer.
		let json = #"{"flag":null,"title":null}"#

		let model = try JSONDecoder().decode(Model.self, from: Data(json.utf8))

		#expect(model.flag == false)
		#expect(model.title == "")
	}

	@Test("Every decode path agrees on an explicit null")
	func allPathsAgreeOnExplicitNull() throws {
		// The regression this guards: the keyed path has its own overload, while
		// `[Fallback<T>]` and a top-level `Fallback<T>` go straight through `init(from:)`.
		// When only the overload handled null, the same stored null meant `nil` in an object
		// and the provider's value in an array.
		let inObject = try JSONDecoder().decode(Model.self, from: Data(#"{"note":null}"#.utf8))
		let inArray = try JSONDecoder().decode([Fallback<MissingNote>].self, from: Data("[null]".utf8))
		let alone = try JSONDecoder().decode(Fallback<MissingNote>.self, from: Data("null".utf8))

		#expect(inObject.note == nil)
		#expect(inArray[0].wrappedValue == nil)
		#expect(alone.wrappedValue == nil)
	}

	@Test("A value outside a keyed container is read the same way")
	func nonKeyedContainersReadValues() throws {
		let inArray = try JSONDecoder().decode(
			[Fallback<MissingNote>].self,
			from: Data(#"["read"]"#.utf8)
		)
		let alone = try JSONDecoder().decode(Fallback<MissingNote>.self, from: Data(#""read""#.utf8))

		#expect(inArray[0].wrappedValue == "read")
		#expect(alone.wrappedValue == "read")
	}

	@Test("An unreadable value outside a keyed container takes the fallback")
	func nonKeyedContainersFallBackForUnreadableValues() throws {
		let inArray = try JSONDecoder().decode(
			[Fallback<MissingNote>].self,
			from: Data("[[1,2]]".utf8)
		)
		let alone = try JSONDecoder().decode(Fallback<MissingNote>.self, from: Data("[1,2]".utf8))

		#expect(inArray[0].wrappedValue == "missing")
		#expect(alone.wrappedValue == "missing")
	}

	@Test("A non-optional value outside a keyed container falls back for null")
	func nonKeyedContainersFallBackForNullNonOptionalValues() throws {
		// The plain branch rather than the optional one, so it is worth pinning that a null
		// there is also the fallback and not a decode failure.
		let inArray = try JSONDecoder().decode([Fallback<FalseFlag>].self, from: Data("[null]".utf8))
		let alone = try JSONDecoder().decode(Fallback<FalseFlag>.self, from: Data("null".utf8))

		#expect(inArray[0].wrappedValue == false)
		#expect(alone.wrappedValue == false)
	}

	@Test("A readable value is kept")
	func readableValueIsKept() throws {
		let identifier = UUID()
		let json = #"{"flag":true,"title":"Algorithms","note":"read","identifier":"\#(identifier)"}"#

		let model = try JSONDecoder().decode(Model.self, from: Data(json.utf8))

		#expect(model.flag)
		#expect(model.title == "Algorithms")
		#expect(model.note == "read")
		#expect(model.identifier == identifier)
	}

	@Test("The fallback is asked for once per value, so two records never share one")
	func fallbackIsEvaluatedPerValue() throws {
		// The wrapper must call `fallbackValue` per record rather than reuse one value: a
		// `static let` provider would give every record the same identifier, which for
		// accounts means sharing one browser session — the thing sessions exist to prevent.
		let models = try JSONDecoder().decode([Model].self, from: Data("[{},{}]".utf8))

		#expect(models.count == 2)
		#expect(models[0].identifier != models[1].identifier)
	}

	@Test("One unreadable record does not take the rest of the list with it")
	func unreadableRecordDoesNotTakeTheList() throws {
		let json = #"[{"flag":"bad"},{"title":"Algorithms"}]"#

		let models = try JSONDecoder().decode([Model].self, from: Data(json.utf8))

		#expect(models.count == 2)
		#expect(models[0].title == "")
		#expect(models[1].title == "Algorithms")
	}

	@Test("Encoding writes the fallback back, so a stored record gains the field")
	func encodingWritesTheFallbackBack() throws {
		// Why a record written before a field existed heals on its next save.
		let model = try JSONDecoder().decode(Model.self, from: Data("{}".utf8))

		let object =
			try JSONSerialization.jsonObject(with: JSONEncoder().encode(model)) as! [String: Any]

		#expect(object["flag"] as? Bool == false)
		#expect(object["title"] as? String == "")
		#expect(object["identifier"] as? String != nil)
		// A nil optional is still written, as an explicit null.
		#expect(object.keys.contains("note"))
	}
}
