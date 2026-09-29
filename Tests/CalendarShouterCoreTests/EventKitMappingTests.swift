import EventKit
import Foundation
import Testing

@testable import CalendarShouterCore

/// Builds an `EKEvent` in a standalone store so the mapping can be exercised
/// without touching the user's real calendars.
@MainActor
private func makeEvent(
	startDate: Date,
	endDate: Date,
	title: String? = "Standup",
	location: String? = nil,
	notes: String? = nil,
	alarms: [EKAlarm]? = nil,
	calendarTitle: String = "Work"
) -> EKEvent {
	let store = EKEventStore()
	let calendar = EKCalendar(for: .event, eventStore: store)
	calendar.title = calendarTitle
	calendar.cgColor = CGColor(red: 0.2, green: 0.4, blue: 0.9, alpha: 1)

	let event = EKEvent(eventStore: store)
	event.calendar = calendar
	event.title = title
	event.startDate = startDate
	event.endDate = endDate
	event.location = location
	event.notes = notes
	if let alarms {
		event.alarms = alarms
	}
	return event
}

@MainActor
@Suite("EventKit mapping")
struct EventKitMappingTests {
	private let startDate = Date(timeIntervalSince1970: 1_700_000_000)

	@Test("A relative alarm fires relative to the event's start")
	func relativeAlarm() throws {
		let event = makeEvent(
			startDate: startDate,
			endDate: startDate.addingTimeInterval(3600),
			alarms: [EKAlarm(relativeOffset: -600)]
		)

		let reminder = try #require(ReminderEvent(event))
		#expect(reminder.fireDates == [startDate.addingTimeInterval(-600)])
	}

	@Test("An absolute alarm fires at its own instant")
	func absoluteAlarm() throws {
		let alarmDate = startDate.addingTimeInterval(-900)
		let event = makeEvent(
			startDate: startDate,
			endDate: startDate.addingTimeInterval(3600),
			alarms: [EKAlarm(absoluteDate: alarmDate)]
		)

		let reminder = try #require(ReminderEvent(event))
		#expect(reminder.fireDates == [alarmDate])
	}

	@Test("Every time-based alarm produces a firing")
	func multipleAlarms() throws {
		let event = makeEvent(
			startDate: startDate,
			endDate: startDate.addingTimeInterval(3600),
			alarms: [EKAlarm(relativeOffset: -300), EKAlarm(relativeOffset: -60)]
		)

		let reminder = try #require(ReminderEvent(event))
		#expect(reminder.fireDates.count == 2)
	}

	@Test("An event without alarms never produces a reminder")
	func noAlarmsIsSkipped() {
		let event = makeEvent(
			startDate: startDate,
			endDate: startDate.addingTimeInterval(3600),
			alarms: []
		)

		#expect(ReminderEvent(event) == nil)
	}

	@Test("A location-based alarm is ignored")
	func locationAlarmIsSkipped() {
		let alarm = EKAlarm(relativeOffset: -600)
		alarm.proximity = .enter
		alarm.structuredLocation = EKStructuredLocation(title: "Office")

		let event = makeEvent(
			startDate: startDate,
			endDate: startDate.addingTimeInterval(3600),
			alarms: [alarm]
		)

		#expect(ReminderEvent(event) == nil)
	}

	// Note: cancelled events are also skipped, but `EKEvent.status` is read-only
	// and only becomes `.canceled` through a real calendar store, so that guard
	// cannot be exercised from a unit test.

	@Test("An event with no calendar is skipped")
	func eventWithoutCalendarIsSkipped() {
		let event = makeEvent(
			startDate: startDate,
			endDate: startDate.addingTimeInterval(3600),
			alarms: [EKAlarm(relativeOffset: -300)]
		)
		event.calendar = nil

		#expect(ReminderEvent(event) == nil)
	}

	@Test("The calendar's title and color are carried over")
	func copiesCalendarMetadata() throws {
		let event = makeEvent(
			startDate: startDate,
			endDate: startDate.addingTimeInterval(3600),
			alarms: [EKAlarm(relativeOffset: -300)],
			calendarTitle: "Personal"
		)

		let reminder = try #require(ReminderEvent(event))
		#expect(reminder.calendar.title == "Personal")
		#expect(reminder.calendar.color.red > 0.1)
		#expect(reminder.calendar.color.blue > 0.5)
	}

	@Test("Blank locations and notes become nil")
	func trimsBlankFields() throws {
		let event = makeEvent(
			startDate: startDate,
			endDate: startDate.addingTimeInterval(3600),
			location: "   ",
			notes: "\n  \t",
			alarms: [EKAlarm(relativeOffset: -300)]
		)

		let reminder = try #require(ReminderEvent(event))
		#expect(reminder.location == nil)
		#expect(reminder.notes == nil)
	}

	@Test("An event's calendar carries the account it belongs to")
	func carriesAccount() throws {
		let event = makeEvent(
			startDate: startDate,
			endDate: startDate.addingTimeInterval(3600),
			alarms: [EKAlarm(relativeOffset: -300)]
		)

		let reminder = try #require(ReminderEvent(event))
		// A standalone calendar has no source, which is reported rather than dropped.
		#expect(reminder.calendar.account.kind == .other)
	}

	@Test("Access levels map from EventKit's statuses")
	func mapsAuthorizationStatuses() {
		#expect(EventKitCalendarService.authorization(from: .notDetermined) == .notDetermined)
		#expect(EventKitCalendarService.authorization(from: .denied) == .denied)
		#expect(EventKitCalendarService.authorization(from: .restricted) == .restricted)
		#expect(EventKitCalendarService.authorization(from: .fullAccess) == .fullAccess)
		#expect(EventKitCalendarService.authorization(from: .writeOnly) == .writeOnly)
	}
}

@Suite("Calendar account grouping")
struct CalendarAccountGroupingTests {
	private func calendar(
		_ title: String,
		account: String,
		kind: CalendarAccountKind
	) -> CalendarInfo {
		CalendarInfo(
			id: "\(account)/\(title)",
			title: title,
			color: RGBColor(red: 0, green: 0, blue: 0),
			account: CalendarAccountRef(id: account, title: account, kind: kind)
		)
	}

	@Test("Calendars are gathered into one group per account")
	func groupsByAccount() {
		let calendars = [
			calendar("Work", account: "iCloud", kind: .calDAV),
			calendar("Home", account: "iCloud", kind: .calDAV),
			calendar("Birthdays", account: "Other", kind: .birthdays),
		]

		let groups = CalendarAccount.grouped(calendars)

		#expect(groups.map(\.title) == ["iCloud", "Other"])
		#expect(groups[0].calendars.map(\.title) == ["Home", "Work"])
		#expect(groups[1].calendars.map(\.title) == ["Birthdays"])
	}

	@Test("Accounts are ordered by kind, so the system collections come last")
	func ordersAccountsByKind() {
		let calendars = [
			calendar("Holidays", account: "Subscribed", kind: .subscribed),
			calendar("Home", account: "On My Mac", kind: .local),
			calendar("Work", account: "iCloud", kind: .calDAV),
			calendar("Birthdays", account: "Other", kind: .birthdays),
			calendar("Mail", account: "Exchange", kind: .exchange),
		]

		let groups = CalendarAccount.grouped(calendars)

		#expect(groups.map(\.kind) == [.local, .exchange, .calDAV, .subscribed, .birthdays])
	}

	@Test("Accounts of the same kind are ordered by name")
	func ordersSameKindByName() {
		let calendars = [
			calendar("A", account: "zoe@example.com", kind: .calDAV),
			calendar("B", account: "ada@example.com", kind: .calDAV),
		]

		let groups = CalendarAccount.grouped(calendars)

		#expect(groups.map(\.title) == ["ada@example.com", "zoe@example.com"])
	}

	@Test("Calendars are ordered by name within their account")
	func ordersCalendarsByName() {
		let calendars = [
			calendar("zulu", account: "iCloud", kind: .calDAV),
			calendar("Alpha", account: "iCloud", kind: .calDAV),
			calendar("mike", account: "iCloud", kind: .calDAV),
		]

		let groups = CalendarAccount.grouped(calendars)

		#expect(groups[0].calendars.map(\.title) == ["Alpha", "mike", "zulu"])
	}

	@Test("No calendars produce no groups")
	func noCalendars() {
		#expect(CalendarAccount.grouped([]).isEmpty)
	}
}

/// Builds an `EKReminder` in a standalone store so the mapping can be exercised
/// without touching the user's real reminders.
@MainActor
private func makeReminder(
	title: String? = "Water the plants",
	dueDateComponents: DateComponents? = nil,
	alarms: [EKAlarm]? = nil,
	isCompleted: Bool = false,
	listTitle: String = "Reminders"
) -> EKReminder {
	let store = EKEventStore()
	let calendar = EKCalendar(for: .reminder, eventStore: store)
	calendar.title = listTitle
	calendar.cgColor = CGColor(red: 0.9, green: 0.4, blue: 0.2, alpha: 1)

	let reminder = EKReminder(eventStore: store)
	reminder.calendar = calendar
	reminder.title = title
	reminder.dueDateComponents = dueDateComponents
	if let alarms {
		reminder.alarms = alarms
	}
	reminder.isCompleted = isCompleted
	return reminder
}

/// A due date built in the current calendar, so expectations do not depend on the
/// machine's time zone.
private func localDueDate(
	year: Int = 2023,
	month: Int = 11,
	day: Int = 14,
	hour: Int? = nil,
	minute: Int? = nil
) -> (components: DateComponents, date: Date) {
	var components = DateComponents()
	components.year = year
	components.month = month
	components.day = day
	components.hour = hour
	components.minute = minute
	return (components, Calendar.current.date(from: components) ?? Date())
}

@MainActor
@Suite("Reminder mapping")
struct ReminderMappingTests {
	private let alarmInstant = Date(timeIntervalSince1970: 1_700_000_000)

	@Test("A reminder with neither a due time nor an alarm never produces a reminder")
	func dueTimeOrAlarmRequired() {
		#expect(ReminderEvent(makeReminder()) == nil)
	}

	@Test("A completed reminder never produces a reminder")
	func completedIsSkipped() {
		let due = localDueDate(hour: 17, minute: 30)
		let reminder = makeReminder(dueDateComponents: due.components, isCompleted: true)

		#expect(ReminderEvent(reminder) == nil)
	}

	@Test("A due time fires at that single instant")
	func dueTimeIsAPoint() throws {
		let due = localDueDate(hour: 17, minute: 30)
		let reminder = makeReminder(dueDateComponents: due.components)

		let mapped = try #require(ReminderEvent(reminder))
		#expect(mapped.fireDates == [due.date])
		#expect(mapped.isAllDay == false)
		#expect(mapped.startDate == due.date)
		#expect(mapped.endDate == due.date)
	}

	@Test("A date-only due date is announced mid-morning as an all-day item")
	func dateOnlyDueIsAllDay() throws {
		let due = localDueDate()
		let reminder = makeReminder(dueDateComponents: due.components)

		let mapped = try #require(ReminderEvent(reminder))
		let startOfDay = Calendar.current.startOfDay(for: due.date)
		let midMorning = try #require(
			Calendar.current.date(byAdding: .hour, value: 9, to: startOfDay)
		)

		#expect(mapped.isAllDay == true)
		#expect(mapped.startDate == startOfDay)
		#expect(mapped.fireDates == [midMorning])
	}

	@Test("An absolute alarm fires at its own instant")
	func absoluteAlarm() throws {
		let alarmDate = alarmInstant.addingTimeInterval(-900)
		let reminder = makeReminder(alarms: [EKAlarm(absoluteDate: alarmDate)])

		let mapped = try #require(ReminderEvent(reminder))
		#expect(mapped.fireDates == [alarmDate])
	}

	@Test("A relative alarm fires relative to the due date")
	func relativeAlarm() throws {
		let due = localDueDate(hour: 17, minute: 30)
		let reminder = makeReminder(
			dueDateComponents: due.components,
			alarms: [EKAlarm(relativeOffset: -600)]
		)

		let mapped = try #require(ReminderEvent(reminder))
		#expect(mapped.fireDates == [due.date.addingTimeInterval(-600)])
	}

	@Test("An alarm replaces the due date rather than adding to it")
	func alarmWinsOverDueDate() throws {
		let due = localDueDate(hour: 17, minute: 30)
		let alarmDate = due.date.addingTimeInterval(-900)
		let reminder = makeReminder(
			dueDateComponents: due.components,
			alarms: [EKAlarm(absoluteDate: alarmDate)]
		)

		let mapped = try #require(ReminderEvent(reminder))
		#expect(mapped.fireDates == [alarmDate])
	}

	@Test("A relative alarm without a due date has nothing to fire from")
	func relativeAlarmWithoutDueIsSkipped() {
		let reminder = makeReminder(alarms: [EKAlarm(relativeOffset: -600)])

		#expect(ReminderEvent(reminder) == nil)
	}

	@Test("The reminder's list and notes are carried over, but the list colour is not")
	func copiesListAndNotes() throws {
		let due = localDueDate(hour: 9)
		let reminder = makeReminder(dueDateComponents: due.components, listTitle: "Errands")
		reminder.notes = "  Take the blue bag  "

		let mapped = try #require(ReminderEvent(reminder))
		#expect(mapped.calendar.title == "Errands")
		// Every reminder list is shown with the same colour, whatever the list's own is.
		#expect(mapped.calendar.color == CalendarInfo.reminderColor)
		#expect(mapped.notes == "Take the blue bag")
		#expect(mapped.location == nil)
	}
}
