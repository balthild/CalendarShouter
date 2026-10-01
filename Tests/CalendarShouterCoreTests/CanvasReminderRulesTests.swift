import Foundation
import Testing

@testable import CalendarShouterCore

/// A fixed calendar so every expectation below is plain arithmetic.
private let utcCalendar: Calendar = {
	var calendar = Calendar(identifier: .gregorian)
	calendar.timeZone = TimeZone(identifier: "UTC")!
	return calendar
}()

private func date(
	_ year: Int,
	_ month: Int,
	_ day: Int,
	_ hour: Int = 0,
	_ minute: Int = 0
)
	-> Date
{
	utcCalendar.date(
		from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute)
	)!
}

private func makeAccount(id: String = "acc-1", addedAt: Date = .distantPast) -> CanvasAccount {
	CanvasAccount(
		id: id,
		domain: "canvas.example.edu",
		baseURL: URL(string: "https://canvas.example.edu")!,
		userID: "7",
		userName: "Student",
		addedAt: addedAt
	)
}

private func makeCourse(id: String = "course-1", accountID: String = "acc-1") -> CanvasCourse {
	CanvasCourse(accountID: accountID, courseID: id, name: "Algorithms", courseCode: "CS301")
}

@discardableResult
private func makeAssignment(
	id: String = "assignment-1",
	course: CanvasCourse = makeCourse(),
	dueAt: Date? = date(2026, 3, 10, 23, 59),
	unlockAt: Date? = nil,
	lockAt: Date? = nil,
	isPublished: Bool = true,
	isSubmitted: Bool = false
) -> CanvasAssignment {
	CanvasAssignment(
		id: id,
		course: course,
		name: "Problem set 4",
		dueAt: dueAt,
		unlockAt: unlockAt,
		lockAt: lockAt,
		isPublished: isPublished,
		isSubmitted: isSubmitted,
		htmlURL: nil
	)
}

@Suite("Canvas reminder rules")
struct CanvasReminderRuleTests {
	@Test("A rule some days before the due date fires that morning")
	func daysBefore() {
		let rule = CanvasReminderRule(kind: .daysBefore, days: 3, time: TimeOfDay(hour: 9, minute: 0))
		let fireDate = rule.fireDate(for: makeAssignment(), calendar: utcCalendar)
		#expect(fireDate == date(2026, 3, 7, 9, 0))
	}

	@Test("A rule on the due day ignores the due time and uses the chosen one")
	func onDueDay() {
		let rule = CanvasReminderRule(kind: .onDueDay, time: TimeOfDay(hour: 8, minute: 30))
		let fireDate = rule.fireDate(for: makeAssignment(), calendar: utcCalendar)
		#expect(fireDate == date(2026, 3, 10, 8, 30))
	}

	@Test("A before-due rule counts back from the due time")
	func beforeDue() {
		let rule = CanvasReminderRule(kind: .beforeDue, minutes: 60)
		let fireDate = rule.fireDate(for: makeAssignment(), calendar: utcCalendar)
		#expect(fireDate == date(2026, 3, 10, 22, 59))
	}

	@Test("A rule with no due date to work from produces nothing")
	func noDueDate() {
		let rule = CanvasReminderRule(kind: .daysBefore, days: 1)
		#expect(rule.fireDate(for: makeAssignment(dueAt: nil), calendar: utcCalendar) == nil)
	}

	@Test("A submitted assignment is skipped whatever the rules say")
	func submittedIsSkipped() {
		let assignment = makeAssignment(isSubmitted: true)
		#expect(!assignment.canProduceReminders)
		#expect(
			CanvasReminderPlanner.fireDates(
				for: assignment,
				rules: [CanvasReminderRule(kind: .beforeDue, minutes: 60)],
				calendar: utcCalendar,
				notBefore: nil
			).isEmpty
		)
	}

	@Test("An unpublished assignment is skipped")
	func unpublishedIsSkipped() {
		#expect(!makeAssignment(isPublished: false).canProduceReminders)
	}

	@Test("An assignment without a due date is skipped")
	func missingDueDateIsSkipped() {
		#expect(!makeAssignment(dueAt: nil).canProduceReminders)
	}

	@Test("A fire time earlier than the assignment unlocks is ignored")
	func beforeUnlockIsIgnored() {
		// The rule lands on 7 March, but the assignment is not available until the 8th.
		let assignment = makeAssignment(unlockAt: date(2026, 3, 8))
		let fires = CanvasReminderPlanner.fireDates(
			for: assignment,
			rules: [CanvasReminderRule(kind: .daysBefore, days: 3, time: TimeOfDay(hour: 9, minute: 0))],
			calendar: utcCalendar,
			notBefore: nil
		)
		#expect(fires.isEmpty)
	}

	@Test("A fire time later than the assignment locks is ignored")
	func afterLockIsIgnored() {
		let assignment = makeAssignment(lockAt: date(2026, 3, 10, 8, 0))
		let fires = CanvasReminderPlanner.fireDates(
			for: assignment,
			rules: [CanvasReminderRule(kind: .onDueDay, time: TimeOfDay(hour: 9, minute: 0))],
			calendar: utcCalendar,
			notBefore: nil
		)
		#expect(fires.isEmpty)
	}

	@Test("A fire time from before the account was added is ignored")
	func beforeAccountActivationIsIgnored() {
		let assignment = makeAssignment()
		let fires = CanvasReminderPlanner.fireDates(
			for: assignment,
			rules: [CanvasReminderRule(kind: .daysBefore, days: 3, time: TimeOfDay(hour: 9, minute: 0))],
			calendar: utcCalendar,
			notBefore: date(2026, 3, 8)
		)
		#expect(fires.isEmpty)
	}

	@Test("A fire time after the account was added survives")
	func afterAccountActivationSurvives() {
		let fires = CanvasReminderPlanner.fireDates(
			for: makeAssignment(),
			rules: [CanvasReminderRule(kind: .daysBefore, days: 3, time: TimeOfDay(hour: 9, minute: 0))],
			calendar: utcCalendar,
			notBefore: date(2026, 3, 1)
		)
		#expect(fires == [date(2026, 3, 7, 9, 0)])
	}

	@Test("Every rule that survives produces a separate fire time, in order")
	func severalRules() {
		let rules = [
			CanvasReminderRule(kind: .beforeDue, minutes: 60),
			CanvasReminderRule(kind: .daysBefore, days: 3, time: TimeOfDay(hour: 9, minute: 0)),
			CanvasReminderRule(kind: .onDueDay, time: TimeOfDay(hour: 8, minute: 0)),
		]
		let event = CanvasReminderPlanner.reminderEvent(
			for: makeAssignment(),
			account: makeAccount(),
			rules: rules,
			calendar: utcCalendar
		)
		#expect(
			event?.fireDates == [
				date(2026, 3, 7, 9, 0),
				date(2026, 3, 10, 8, 0),
				date(2026, 3, 10, 22, 59),
			]
		)
	}

	@Test("An assignment whose rules all fall outside its window produces no event")
	func noEventWhenNothingFires() {
		let assignment = makeAssignment(unlockAt: date(2026, 3, 9))
		let event = CanvasReminderPlanner.reminderEvent(
			for: assignment,
			account: makeAccount(),
			rules: [CanvasReminderRule(kind: .daysBefore, days: 3, time: TimeOfDay(hour: 9, minute: 0))],
			calendar: utcCalendar
		)
		#expect(event == nil)
	}

	@Test("The event is labelled with the course and identifies the account")
	func eventLabelling() {
		let course = makeCourse()
		let event = CanvasReminderPlanner.reminderEvent(
			for: makeAssignment(course: course),
			account: makeAccount(),
			rules: [CanvasReminderRule(kind: .beforeDue, minutes: 60)],
			calendar: utcCalendar
		)
		#expect(event?.id == "canvas:assignment-1")
		#expect(event?.title == "Problem set 4")
		#expect(event?.calendar.id == course.id)
		#expect(event?.calendar.title == "Algorithms")
		#expect(event?.calendar.account.id == "acc-1")
		#expect(event?.calendar.color == CanvasPalette.courseColor)
	}

	@Test("Nonsense parameters are clamped rather than trusted")
	func normalisation() {
		let rule = CanvasReminderRule(
			kind: .daysBefore,
			days: -5,
			time: TimeOfDay(hour: 30, minute: 90),
			minutes: 0
		)
		#expect(rule.normalized.days == 0)
		#expect(rule.normalized.time == TimeOfDay(hour: 23, minute: 59))
		#expect(rule.normalized.minutes == 1)
	}
}
