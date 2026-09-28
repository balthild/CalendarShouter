import Foundation
import Testing

@testable import CalendarShouterCore

private func makeDefaults() -> UserDefaults {
	let suiteName = "CalendarShouterTests.\(UUID().uuidString)"
	let defaults = UserDefaults(suiteName: suiteName)!
	defaults.removePersistentDomain(forName: suiteName)
	return defaults
}

@MainActor
@Suite("SettingsStore")
struct SettingsStoreTests {
	@Test("Defaults match the documented out-of-the-box behaviour")
	func defaultValues() {
		let store = SettingsStore(defaults: makeDefaults())

		#expect(store.showMenuBarIcon == true)
		#expect(store.showMissedReminders == true)
		#expect(store.enabledCalendarIDs.isEmpty)
		#expect(store.soundName == SettingsStore.defaultSoundName)
	}

	@Test("Reminders are off for every calendar until one is switched on")
	func remindersDisabledByDefault() {
		let store = SettingsStore(defaults: makeDefaults())

		#expect(store.isReminderEnabled(forCalendarID: "work") == false)
		store.setReminderEnabled(true, forCalendarID: "work")
		#expect(store.isReminderEnabled(forCalendarID: "work"))
		// Enabling one calendar leaves the others alone.
		#expect(store.isReminderEnabled(forCalendarID: "personal") == false)
	}

	@Test("Values survive being reloaded from the same suite")
	func persistsAcrossInstances() {
		let defaults = makeDefaults()

		let first = SettingsStore(defaults: defaults)
		first.showMenuBarIcon = false
		first.showMissedReminders = false
		first.soundName = "Ping"
		first.setReminderEnabled(true, forCalendarID: "work")

		let second = SettingsStore(defaults: defaults)
		#expect(second.showMenuBarIcon == false)
		#expect(second.showMissedReminders == false)
		#expect(second.soundName == "Ping")
		#expect(second.enabledCalendarIDs == ["work"])
	}

	@Test("Switching a calendar back off removes it from the enabled set")
	func disablingRemovesCalendar() {
		let store = SettingsStore(defaults: makeDefaults())

		store.setReminderEnabled(true, forCalendarID: "work")
		store.setReminderEnabled(false, forCalendarID: "work")

		#expect(store.isReminderEnabled(forCalendarID: "work") == false)
		#expect(store.enabledCalendarIDs.isEmpty)
	}

	@Test("The legacy disabled-calendars key is ignored")
	func ignoresLegacyDisabledKey() {
		let defaults = makeDefaults()
		// The old allow-list was inverted; the store must not read it back.
		defaults.set(["work"], forKey: "disabledCalendarIDs")

		let store = SettingsStore(defaults: defaults)

		#expect(store.enabledCalendarIDs.isEmpty)
		#expect(store.isReminderEnabled(forCalendarID: "work") == false)
	}
}

@Suite("SoundCatalog")
struct SoundCatalogTests {
	@Test("Always offers a silent option")
	func offersNoSound() {
		let catalog = SoundCatalog(directories: [])
		#expect(catalog.choices == [.none])
	}

	@Test("Lists sounds found in the given directories, sorted and de-duplicated")
	func listsSounds() throws {
		let directory = FileManager.default.temporaryDirectory
			.appendingPathComponent(UUID().uuidString, isDirectory: true)
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: directory) }

		for fileName in ["Ping.aiff", "Glass.aiff", "Ping.wav", "notes.txt"] {
			try Data().write(to: directory.appendingPathComponent(fileName))
		}

		let catalog = SoundCatalog(directories: [directory])
		#expect(catalog.choices == [.none, .system(name: "Glass"), .system(name: "Ping")])
	}

	@Test("Lists later directories after earlier ones, and keeps a duplicate only once")
	func keepsDirectoryOrder() throws {
		let temporary = FileManager.default.temporaryDirectory
		let fileManager = FileManager.default
		let systemDirectory = temporary.appendingPathComponent(UUID().uuidString, isDirectory: true)
		let userDirectory = temporary.appendingPathComponent(UUID().uuidString, isDirectory: true)
		defer {
			for directory in [systemDirectory, userDirectory] {
				try? fileManager.removeItem(at: directory)
			}
		}
		for directory in [systemDirectory, userDirectory] {
			try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
		}

		// "Aaa" and "Zzz" are in both directories; only the system copies should be listed.
		for fileName in ["Zzz.aiff", "Aaa.aiff"] {
			try Data().write(to: systemDirectory.appendingPathComponent(fileName))
		}
		for fileName in ["Aaa.aiff", "Zzz.aiff", "Mine.aiff"] {
			try Data().write(to: userDirectory.appendingPathComponent(fileName))
		}

		let catalog = SoundCatalog(directories: [systemDirectory, userDirectory])
		#expect(
			catalog.choices == [
				.none,
				.system(name: "Aaa"),
				.system(name: "Zzz"),
				.system(name: "Mine"),
			]
		)
	}

	@Test("Maps a stored sound name back to a choice")
	func roundTripsSoundNames() {
		#expect(SoundChoice.from(soundName: "") == .none)
		#expect(SoundChoice.from(soundName: "Glass") == .system(name: "Glass"))
		#expect(SoundChoice.system(name: "Glass").soundName == "Glass")
		#expect(SoundChoice.none.soundName == "")
	}
}

@Suite("SnoozeOption")
struct SnoozeOptionTests {
	@Test("Offers the documented delays")
	func offersDocumentedDelays() {
		#expect(SnoozeOption.allCases.map(\.minutes) == [5, 10, 15, 30])
	}

	@Test("Converts minutes to a time interval")
	func convertsToTimeInterval() {
		#expect(SnoozeOption.fifteenMinutes.timeInterval == 900)
	}
}
