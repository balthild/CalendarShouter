import Foundation
import Testing

@testable import CalendarShouterCore

private let referenceDate = Date(timeIntervalSince1970: 1_700_000_000)

private func makeFire(
	id: String,
	ended: Bool,
	isLate: Bool,
	isSnooze: Bool = false
) -> ReminderFire {
	let start = referenceDate.addingTimeInterval(-3600)
	let end =
		ended
		? referenceDate.addingTimeInterval(-60)
		: referenceDate.addingTimeInterval(3600)
	let event = ReminderEvent(
		id: id,
		title: id,
		startDate: start,
		endDate: end,
		isAllDay: false,
		location: nil,
		notes: nil,
		calendar: CalendarInfo(
			id: "cal-1",
			title: "Work",
			color: RGBColor(red: 0, green: 0, blue: 0),
			account: CalendarAccountRef(id: "account-1", title: "iCloud", kind: .calDAV)
		),
		fireDates: [start]
	)
	return ReminderFire(event: event, fireDate: start, isSnooze: isSnooze, isLate: isLate)
}

@Suite("ReminderPresentation")
struct ReminderPresentationTests {
	@Test("Four ended missed reminders collapse into a backlog")
	func collapsesFour() {
		let fires = (1...4).map { makeFire(id: "e\($0)", ended: true, isLate: true) }
		#expect(ReminderPresentation.isBacklog(fires, now: referenceDate))
	}

	@Test("Three ended missed reminders do not collapse")
	func keepsThree() {
		let fires = (1...3).map { makeFire(id: "e\($0)", ended: true, isLate: true) }
		#expect(ReminderPresentation.isBacklog(fires, now: referenceDate) == false)
	}

	@Test("Late reminders for a still-running event do not collapse")
	func keepsOngoingEvents() {
		let fires = (1...5).map { makeFire(id: "e\($0)", ended: false, isLate: true) }
		#expect(ReminderPresentation.isBacklog(fires, now: referenceDate) == false)
	}

	@Test("A batch of on-time reminders does not collapse")
	func keepsOnTimeReminders() {
		let fires = (1...5).map { makeFire(id: "e\($0)", ended: true, isLate: false) }
		#expect(ReminderPresentation.isBacklog(fires, now: referenceDate) == false)
	}

	@Test("Snoozed reminders are never collapsed")
	func keepsSnoozes() {
		let fires = (1...5).map { makeFire(id: "e\($0)", ended: true, isLate: true, isSnooze: true) }
		#expect(ReminderPresentation.endedMissed(fires, now: referenceDate).isEmpty)
	}
}
