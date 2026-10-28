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

private func makeUpcomingFire(id: String, offset: TimeInterval) -> ReminderFire {
	let fireDate = referenceDate.addingTimeInterval(offset)
	let event = ReminderEvent(
		id: id,
		title: id,
		startDate: fireDate,
		endDate: fireDate,
		isAllDay: false,
		location: nil,
		notes: nil,
		calendar: CalendarInfo(
			id: "cal-1",
			title: "Work",
			color: RGBColor(red: 0, green: 0, blue: 0),
			account: CalendarAccountRef(id: "account-1", title: "iCloud", kind: .calDAV)
		),
		fireDates: [fireDate]
	)
	return ReminderFire(event: event, fireDate: fireDate, isSnooze: false)
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

	@Test("Upcoming reminders drop the past and list the soonest first")
	func ordersUpcoming() {
		let fires = [
			makeUpcomingFire(id: "later", offset: 3600),
			makeUpcomingFire(id: "past", offset: -60),
			makeUpcomingFire(id: "next", offset: 60),
			makeUpcomingFire(id: "now", offset: 0),
		]

		let upcoming = ReminderPresentation.upcoming(fires, now: referenceDate)
		#expect(upcoming.map(\.event.id) == ["now", "next", "later"])
	}

	@Test("Upcoming reminders are capped at the limit")
	func capsUpcoming() {
		let fires = (1...12).map { makeUpcomingFire(id: "f\($0)", offset: Double($0) * 60) }

		let upcoming = ReminderPresentation.upcoming(fires, now: referenceDate)
		#expect(upcoming.count == ReminderPresentation.upcomingLimit)
		#expect(upcoming.first?.event.id == "f1")
		#expect(upcoming.last?.event.id == "f10")
	}
}
