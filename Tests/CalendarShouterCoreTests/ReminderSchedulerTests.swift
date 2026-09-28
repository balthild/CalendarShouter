import Foundation
import Testing

@testable import CalendarShouterCore

/// Base instant used by the tests, so every expectation is readable arithmetic.
private let referenceDate = Date(timeIntervalSince1970: 1_700_000_000)

private func makeDefaults() -> UserDefaults {
	// A fresh suite per test keeps persisted state from leaking between them.
	let suiteName = "CalendarShouterTests.\(UUID().uuidString)"
	let defaults = UserDefaults(suiteName: suiteName)!
	defaults.removePersistentDomain(forName: suiteName)
	return defaults
}

private func makeCalendar(id: String = "cal-1", title: String = "Work") -> CalendarInfo {
	CalendarInfo(
		id: id,
		title: title,
		color: RGBColor(red: 0.2, green: 0.4, blue: 0.9),
		account: CalendarAccountRef(id: "account-1", title: "iCloud", kind: .calDAV)
	)
}

/// A store with the given calendars switched on.
///
/// Reminders are off until a calendar is opted into, so a test that expects one to fire
/// has to say which calendar it comes from.
@MainActor
private func makeSettings(
	defaults: UserDefaults,
	enabling calendarIDs: [String] = ["cal-1"]
) -> SettingsStore {
	let settings = SettingsStore(defaults: defaults)
	for calendarID in calendarIDs {
		settings.setReminderEnabled(true, forCalendarID: calendarID)
	}
	return settings
}

private func makeEvent(
	id: String = "event-1",
	title: String = "Standup",
	startDate: Date = referenceDate,
	calendarID: String = "cal-1",
	fireDates: [Date]
) -> ReminderEvent {
	ReminderEvent(
		id: id,
		title: title,
		startDate: startDate,
		endDate: startDate.addingTimeInterval(1800),
		isAllDay: false,
		location: nil,
		notes: nil,
		calendar: makeCalendar(id: calendarID),
		fireDates: fireDates
	)
}

@MainActor
@Suite("ReminderScheduler")
struct ReminderSchedulerTests {
	private func makeScheduler(
		service: FakeCalendarService,
		settings: SettingsStore,
		clock: FakeClock,
		defaults: UserDefaults
	) -> ReminderScheduler {
		ReminderScheduler(
			service: service,
			settings: settings,
			clock: clock,
			defaults: defaults
		)
	}

	@Test("Fires a reminder when its alarm time arrives")
	func firesAtAlarmTime() {
		let defaults = makeDefaults()
		let clock = FakeClock(now: referenceDate)
		let service = FakeCalendarService()
		service.eventsToReturn = [
			makeEvent(fireDates: [referenceDate.addingTimeInterval(60)])
		]

		let scheduler = makeScheduler(
			service: service,
			settings: makeSettings(defaults: defaults),
			clock: clock,
			defaults: defaults
		)
		var fired: [ReminderFire] = []
		scheduler.onFire = { fired.append(contentsOf: $0) }

		scheduler.reload()
		#expect(fired.isEmpty)

		clock.advance(by: 60)
		#expect(fired.count == 1)
		#expect(fired.first?.event.id == "event-1")
	}

	@Test("Does not fire for calendars the user has not switched on")
	func respectsDisabledCalendars() {
		let defaults = makeDefaults()
		let clock = FakeClock(now: referenceDate)
		let service = FakeCalendarService()
		service.eventsToReturn = [
			makeEvent(fireDates: [referenceDate.addingTimeInterval(60)])
		]

		// A different calendar is opted into, so the event's own calendar is not.
		let settings = makeSettings(defaults: defaults, enabling: ["other"])

		let scheduler = makeScheduler(
			service: service,
			settings: settings,
			clock: clock,
			defaults: defaults
		)
		var fired: [ReminderFire] = []
		scheduler.onFire = { fired.append(contentsOf: $0) }

		scheduler.reload()
		clock.advance(by: 60)

		#expect(fired.isEmpty)
	}

	@Test("Ignores alarms that are older than the grace period")
	func ignoresMissedAlarms() {
		let defaults = makeDefaults()
		let clock = FakeClock(now: referenceDate)
		let service = FakeCalendarService()
		service.eventsToReturn = [
			makeEvent(fireDates: [referenceDate.addingTimeInterval(-3600)])
		]

		let scheduler = makeScheduler(
			service: service,
			settings: makeSettings(defaults: defaults),
			clock: clock,
			defaults: defaults
		)
		var fired: [ReminderFire] = []
		scheduler.onFire = { fired.append(contentsOf: $0) }

		scheduler.reload()
		clock.advance(by: 1)

		#expect(fired.isEmpty)
	}

	@Test("Keeps alarms inside the grace window but drops the one on its edge")
	func gracePeriodBoundary() {
		let defaults = makeDefaults()
		let clock = FakeClock(now: referenceDate)
		let service = FakeCalendarService()
		// The window starts at `now - 60`; the boundary is excluded, one second inside is kept.
		service.eventsToReturn = [
			makeEvent(id: "at-edge", fireDates: [referenceDate.addingTimeInterval(-60)]),
			makeEvent(id: "inside", fireDates: [referenceDate.addingTimeInterval(-59)]),
		]

		let scheduler = makeScheduler(
			service: service,
			settings: makeSettings(defaults: defaults),
			clock: clock,
			defaults: defaults
		)
		var fired: [ReminderFire] = []
		scheduler.onFire = { fired.append(contentsOf: $0) }

		scheduler.reload()

		#expect(fired.map(\.event.id) == ["inside"])
	}

	@Test("Never shows the same alarm twice across reloads")
	func doesNotFireTwice() {
		let defaults = makeDefaults()
		let clock = FakeClock(now: referenceDate)
		let service = FakeCalendarService()
		service.eventsToReturn = [
			makeEvent(fireDates: [referenceDate.addingTimeInterval(60)])
		]

		let scheduler = makeScheduler(
			service: service,
			settings: makeSettings(defaults: defaults),
			clock: clock,
			defaults: defaults
		)
		var fired: [ReminderFire] = []
		scheduler.onFire = { fired.append(contentsOf: $0) }

		scheduler.reload()
		clock.advance(by: 60)
		#expect(fired.count == 1)

		scheduler.reload()
		#expect(fired.count == 1)
	}

	@Test("Snoozing shows the reminder again after the chosen delay")
	func snoozeRefires() {
		let defaults = makeDefaults()
		let clock = FakeClock(now: referenceDate)
		let service = FakeCalendarService()
		service.eventsToReturn = [
			makeEvent(fireDates: [referenceDate.addingTimeInterval(60)])
		]

		let scheduler = makeScheduler(
			service: service,
			settings: makeSettings(defaults: defaults),
			clock: clock,
			defaults: defaults
		)
		var fired: [ReminderFire] = []
		scheduler.onFire = { fired.append(contentsOf: $0) }

		scheduler.reload()
		clock.advance(by: 60)
		let original = try! #require(fired.first)

		scheduler.snooze(original, by: .tenMinutes)
		clock.advance(by: 9 * 60)
		#expect(fired.count == 1)

		clock.advance(by: 60)
		#expect(fired.count == 2)
		#expect(fired.last?.isSnooze == true)
	}

	@Test("Fires several reminders due at the same instant together")
	func firesSimultaneousRemindersTogether() {
		let defaults = makeDefaults()
		let clock = FakeClock(now: referenceDate)
		let service = FakeCalendarService()
		let fireDate = referenceDate.addingTimeInterval(60)
		service.eventsToReturn = [
			makeEvent(id: "a", calendarID: "cal-a", fireDates: [fireDate]),
			makeEvent(id: "b", calendarID: "cal-b", fireDates: [fireDate]),
		]

		let scheduler = makeScheduler(
			service: service,
			settings: makeSettings(defaults: defaults, enabling: ["cal-a", "cal-b"]),
			clock: clock,
			defaults: defaults
		)
		var batches: [[ReminderFire]] = []
		scheduler.onFire = { batches.append($0) }

		scheduler.reload()
		clock.advance(by: 60)

		#expect(batches.count == 1)
		#expect(batches.first?.count == 2)
	}

	@Test("Delivers reminders in chronological order over time")
	func deliversInOrder() {
		let defaults = makeDefaults()
		let clock = FakeClock(now: referenceDate)
		let service = FakeCalendarService()
		service.eventsToReturn = [
			makeEvent(id: "later", fireDates: [referenceDate.addingTimeInterval(120)]),
			makeEvent(id: "sooner", fireDates: [referenceDate.addingTimeInterval(60)]),
		]

		let scheduler = makeScheduler(
			service: service,
			settings: makeSettings(defaults: defaults),
			clock: clock,
			defaults: defaults
		)
		var fired: [ReminderFire] = []
		scheduler.onFire = { fired.append(contentsOf: $0) }

		scheduler.reload()
		clock.advance(by: 180)

		#expect(fired.map(\.event.id) == ["sooner", "later"])
	}

	@Test("Dismissed reminders are not restored by a reload")
	func dismissedStayDismissed() {
		let defaults = makeDefaults()
		let clock = FakeClock(now: referenceDate)
		let service = FakeCalendarService()
		service.eventsToReturn = [
			makeEvent(fireDates: [referenceDate.addingTimeInterval(60)])
		]

		let scheduler = makeScheduler(
			service: service,
			settings: makeSettings(defaults: defaults),
			clock: clock,
			defaults: defaults
		)
		var fired: [ReminderFire] = []
		scheduler.onFire = { fired.append(contentsOf: $0) }

		scheduler.reload()
		clock.advance(by: 60)
		let shown = try! #require(fired.first)

		// The user ignores it, then the calendar store changes underneath us.
		scheduler.dismiss(shown)
		scheduler.reload()

		#expect(scheduler.upcomingFires.isEmpty)
		#expect(clock.hasPendingTasks == false)
	}

	@Test("Snoozed reminders survive a reload that no longer sees the event")
	func snoozeSurvivesReload() {
		let defaults = makeDefaults()
		let clock = FakeClock(now: referenceDate)
		let service = FakeCalendarService()
		service.eventsToReturn = [
			makeEvent(fireDates: [referenceDate.addingTimeInterval(60)])
		]

		let scheduler = makeScheduler(
			service: service,
			settings: makeSettings(defaults: defaults),
			clock: clock,
			defaults: defaults
		)
		var fired: [ReminderFire] = []
		scheduler.onFire = { fired.append(contentsOf: $0) }

		scheduler.reload()
		clock.advance(by: 60)
		let original = try! #require(fired.first)
		scheduler.snooze(original, by: .fiveMinutes)

		// The event disappears from the visible window.
		service.eventsToReturn = []
		scheduler.reload()

		clock.advance(by: 5 * 60)
		#expect(fired.count == 2)
	}

	@Test("Reloading queries the calendar for the configured window")
	func reloadQueriesLookaheadWindow() {
		let defaults = makeDefaults()
		let clock = FakeClock(now: referenceDate)
		let service = FakeCalendarService()
		let lookahead: TimeInterval = 3600

		let scheduler = ReminderScheduler(
			service: service,
			settings: makeSettings(defaults: defaults),
			clock: clock,
			defaults: defaults,
			lookahead: lookahead
		)
		scheduler.reload()

		let range = try! #require(service.requestedRanges.first)
		#expect(range.end == referenceDate.addingTimeInterval(lookahead))
	}
}
