import AppKit
import Testing

@testable import CalendarShouterCore

@Suite("SettingsTab")
struct SettingsTabTests {
	@Test("Every tab maps back from its toolbar item identifier")
	func roundTripsIdentifiers() {
		for tab in SettingsTab.allCases {
			#expect(SettingsTab.from(toolbarItemIdentifier: tab.toolbarItemIdentifier) == tab)
		}
	}

	@Test("An unrecognised toolbar item identifier maps to no tab")
	func rejectsUnknownIdentifier() {
		#expect(
			SettingsTab.from(toolbarItemIdentifier: NSToolbarItem.Identifier("tab.unknown")) == nil
		)
	}

	@Test("Toolbar item identifiers are unique")
	func identifiersAreUnique() {
		let identifiers = SettingsTab.allCases.map(\.toolbarItemIdentifier.rawValue)
		#expect(Set(identifiers).count == identifiers.count)
	}
}

@MainActor
@Suite("SettingsSelection")
struct SettingsSelectionTests {
	@Test("Changing the tab reports the new selection")
	func reportsTabChange() {
		let selection = SettingsSelection(tab: .general)
		var reported: [SettingsTab] = []
		selection.onTabChange = { reported.append($0) }

		selection.tab = .canvas

		#expect(reported == [.canvas])
	}

	@Test("Setting the same tab again does not report a change")
	func ignoresUnchangedTab() {
		let selection = SettingsSelection(tab: .general)
		var reported: [SettingsTab] = []
		selection.onTabChange = { reported.append($0) }

		selection.tab = .general

		#expect(reported.isEmpty)
	}
}
