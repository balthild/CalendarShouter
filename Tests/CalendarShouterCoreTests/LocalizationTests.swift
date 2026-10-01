import Foundation
import Testing

@testable import CalendarShouterCore

/// Guards against the two localizations drifting apart.
@Suite("Localization")
struct LocalizationTests {
	/// Locates the checked-in string catalog.
	private static func catalogURL() -> URL? {
		// `#filePath` points at this file, which sits beside the package's test
		// target, so walk up to the package root.
		var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
		for _ in 0..<4 {
			let candidate =
				directory
				.appendingPathComponent("Sources/CalendarShouterCore/Resources/Localizable.xcstrings")
			if FileManager.default.fileExists(atPath: candidate.path) {
				return candidate
			}
			directory = directory.deletingLastPathComponent()
		}
		return nil
	}

	private struct Catalog: Decodable {
		struct Entry: Decodable {
			struct Localization: Decodable {
				struct StringUnit: Decodable {
					let state: String
					let value: String
				}
				let stringUnit: StringUnit
			}
			let localizations: [String: Localization]?
		}
		let sourceLanguage: String
		let strings: [String: Entry]
	}

	private func loadCatalog() throws -> Catalog {
		let url = try #require(Self.catalogURL(), "Localizable.xcstrings was not found")
		let data = try Data(contentsOf: url)
		return try JSONDecoder().decode(Catalog.self, from: data)
	}

	@Test("Sources English strings from a catalog whose source language is English")
	func sourceLanguageIsEnglish() throws {
		#expect(try loadCatalog().sourceLanguage == "en")
	}

	@Test("Keys are identifiers rather than English text")
	func keysAreIdentifiers() throws {
		let identifier = /[a-z][A-Za-z0-9]*/
		let offenders = try loadCatalog().strings.keys.filter { $0.wholeMatch(of: identifier) == nil }
		#expect(
			offenders.isEmpty,
			"Keys that are not lowerCamelCase identifiers: \(offenders.sorted().joined(separator: ", "))"
		)
	}

	@Test("Every key is translated into both supported languages")
	func allKeysTranslated() throws {
		let catalog = try loadCatalog()
		var missing: [String] = []

		for (key, entry) in catalog.strings {
			for language in ["en", "zh-Hans"] {
				guard let localization = entry.localizations?[language] else {
					missing.append("\(key) [\(language): absent]")
					continue
				}
				if localization.stringUnit.state != "translated"
					|| localization.stringUnit.value.isEmpty
				{
					missing.append("\(key) [\(language): \(localization.stringUnit.state)]")
				}
			}
		}

		#expect(missing.isEmpty, "Untranslated keys: \(missing.sorted().joined(separator: ", "))")
	}

	@Test("Canvas rule labels hold one placeholder per input control")
	func canvasRuleLabelsAreSegmented() throws {
		let catalog = try loadCatalog()
		let expected = [
			"canvasRuleDaysTemplate": 2,
			"canvasRuleOnDueDayTemplate": 1,
			"canvasRuleOffsetTemplate": 1,
		]

		for (key, count) in expected {
			for language in ["en", "zh-Hans"] {
				let value = try #require(
					catalog.strings[key]?.localizations?[language]?.stringUnit.value,
					"\(key) [\(language)] is missing"
				)
				#expect(
					value.components(separatedBy: "{}").count - 1 == count,
					"\(key) [\(language)]: the row has \(count) input controls"
				)
			}
		}
	}

	@Test("Generated lookups resolve against the package bundle")
	func resolvesFromPackageBundle() {
		// A missing value falls back to the key itself, so an empty or
		// key-shaped result means the catalog is not being found or is incomplete.
		let ignore = String(localizable: .ignore)
		#expect(ignore.isEmpty == false)
		#expect(ignore != "ignore")
	}
}
