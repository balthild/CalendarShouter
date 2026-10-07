import Foundation
import Testing

@testable import CalendarShouterCore

private func makeDefaults() -> UserDefaults {
	let suiteName = "CalendarShouterTests.\(UUID().uuidString)"
	let defaults = UserDefaults(suiteName: suiteName)!
	defaults.removePersistentDomain(forName: suiteName)
	return defaults
}

private let referenceDate = Date(timeIntervalSince1970: 1_700_000_000)

/// The keys the scheduler used to write into the settings domain.
private let legacyKeys = [
	"handledFireIDs",
	"schedulerLastEvaluationDate",
	"calendarActivationDates",
	"reminderAcknowledgementTimes",
	"snoozedReminders",
	"remindersActivationDate",
]

private func makeEvent(id: String = "event-1", fireDates: [Date]) -> ReminderEvent {
	ReminderEvent(
		id: id,
		title: "Standup",
		startDate: referenceDate,
		endDate: referenceDate.addingTimeInterval(1800),
		isAllDay: false,
		location: nil,
		notes: nil,
		calendar: CalendarInfo(
			id: "cal-1",
			title: "Work",
			color: RGBColor(red: 0.2, green: 0.4, blue: 0.9),
			account: CalendarAccountRef(id: "account-1", title: "iCloud", kind: .calDAV)
		),
		fireDates: fireDates
	)
}

@MainActor
@Suite("ReminderStateStore")
struct ReminderStateStoreTests {
	@Test("A state survives a round trip")
	func roundTrip() {
		let defaults = makeDefaults()
		let store = UserDefaultsReminderStateStore(defaults: defaults)
		let state = ReminderState(
			handledFireIDs: ["a@1", "b@2"],
			lastEvaluationDate: referenceDate,
			calendarActivationDates: ["cal-1": referenceDate],
			remindersActivationDate: referenceDate,
			acknowledgements: ["event-1": referenceDate],
			snoozes: [
				PersistedSnooze(
					event: makeEvent(fireDates: [referenceDate]),
					fireDate: referenceDate.addingTimeInterval(300)
				)
			]
		)

		store.save(state)

		#expect(store.load() == state)
	}

	@Test("The state is stored as a property-list dictionary, not a blob")
	func storedAsADictionary() {
		let defaults = makeDefaults()
		let store = UserDefaultsReminderStateStore(defaults: defaults)

		store.save(ReminderState(handledFireIDs: ["a@1"]))

		#expect(defaults.dictionary(forKey: "reminderState") != nil)
		#expect(defaults.data(forKey: "reminderState") == nil)
	}

	@Test("Nothing saved loads as an empty state, without quarantining anything")
	func absentState() {
		let defaults = makeDefaults()
		let store = UserDefaultsReminderStateStore(defaults: defaults)

		#expect(store.load() == ReminderState())
		#expect(defaults.data(forKey: PersistedJSON.quarantineKey(for: "reminderState")) == nil)
	}

	@Test("A value that no longer decodes is kept aside instead of being lost")
	func unreadableStateIsQuarantined() {
		let defaults = makeDefaults()
		let store = UserDefaultsReminderStateStore(defaults: defaults)
		let stored = Data(#"{"handledFireIDs":42}"#.utf8)
		defaults.set(stored, forKey: "reminderState")

		#expect(store.load() == ReminderState())
		#expect(defaults.data(forKey: "reminderState") == stored)
		#expect(defaults.data(forKey: PersistedJSON.quarantineKey(for: "reminderState")) == stored)
	}

	@Test("Bookkeeping and settings do not share a domain")
	func domainsAreSeparate() {
		let settingsDomain = makeDefaults()
		let stateDomain = makeDefaults()
		let settings = SettingsStore(defaults: settingsDomain)
		let store = UserDefaultsReminderStateStore(defaults: stateDomain)

		settings.showMissedReminders = false
		store.save(ReminderState(handledFireIDs: ["a@1"]))

		#expect(settingsDomain.stringArray(forKey: "handledFireIDs") == nil)
		#expect(stateDomain.object(forKey: "showMissedReminders") == nil)
	}

	@Test("The keys the scheduler used to keep in the settings domain are removed")
	func legacyKeysArePurged() {
		let defaults = makeDefaults()
		for key in legacyKeys {
			defaults.set(Data("x".utf8), forKey: key)
		}

		UserDefaultsReminderStateStore.removeLegacyKeys(from: defaults)

		for key in legacyKeys {
			#expect(defaults.object(forKey: key) == nil)
		}
	}
}

@MainActor
@Suite("ReminderScheduler state")
struct ReminderSchedulerStateTests {
	@Test("Dismissing writes to the state store, not the settings domain")
	func schedulerWritesOnlyTheStateStore() {
		let settingsDomain = makeDefaults()
		let clock = FakeClock(now: referenceDate)
		let service = FakeCalendarService()
		service.eventsToReturn = [makeEvent(fireDates: [referenceDate.addingTimeInterval(60)])]
		let settings = SettingsStore(defaults: settingsDomain)
		settings.setReminderEnabled(true, forCalendarID: "cal-1")
		let store = InMemoryReminderStateStore()
		let scheduler = ReminderScheduler(
			service: service,
			settings: settings,
			clock: clock,
			stateStore: store
		)
		var fired: [ReminderFire] = []
		scheduler.onFire = { fired.append(contentsOf: $0) }

		scheduler.reload()
		clock.advance(by: 60)
		let shown = try! #require(fired.first)
		scheduler.dismiss(shown)

		#expect(store.state.handledFireIDs.contains(shown.id))
		for key in legacyKeys {
			#expect(settingsDomain.object(forKey: key) == nil)
		}
		#expect(settingsDomain.stringArray(forKey: "enabledCalendarIDs") == ["cal-1"])
	}

	@Test("A state store over the same defaults carries a snooze to the next scheduler")
	func snoozeSurvivesThroughTheStore() {
		let defaults = makeDefaults()
		let service = FakeCalendarService()
		service.eventsToReturn = [makeEvent(fireDates: [referenceDate.addingTimeInterval(60)])]
		let settings = SettingsStore(defaults: defaults)
		settings.setReminderEnabled(true, forCalendarID: "cal-1")

		let firstClock = FakeClock(now: referenceDate)
		let first = ReminderScheduler(
			service: service,
			settings: settings,
			clock: firstClock,
			stateStore: UserDefaultsReminderStateStore(defaults: defaults)
		)
		var fired: [ReminderFire] = []
		first.onFire = { fired.append(contentsOf: $0) }
		first.reload()
		firstClock.advance(by: 60)
		let original = try! #require(fired.first)
		first.snooze(original, by: .fiveMinutes)

		service.eventsToReturn = []
		let secondClock = FakeClock(now: referenceDate.addingTimeInterval(120))
		let second = ReminderScheduler(
			service: service,
			settings: settings,
			clock: secondClock,
			stateStore: UserDefaultsReminderStateStore(defaults: defaults)
		)
		var refired: [ReminderFire] = []
		second.onFire = { refired.append(contentsOf: $0) }
		second.reload()

		secondClock.advance(by: 5 * 60)

		#expect(refired.count == 1)
		#expect(refired.first?.isSnooze == true)
	}
}
