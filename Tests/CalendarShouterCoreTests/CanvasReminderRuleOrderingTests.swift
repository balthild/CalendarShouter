import Foundation
import Testing

@testable import CalendarShouterCore

@Suite("Canvas reminder rule ordering")
struct CanvasReminderRuleOrderingTests {
	private func rule(
		kind: CanvasReminderRule.Kind,
		days: Int = 1,
		hour: Int = 9,
		minute: Int = 0,
		minutes: Int = 60
	) -> CanvasReminderRule {
		CanvasReminderRule(
			kind: kind,
			days: days,
			time: TimeOfDay(hour: hour, minute: minute),
			minutes: minutes
		)
	}

	@Test("Rules are listed by kind, then by how early they fire")
	func rulesAreOrdered() {
		let shuffled = [
			rule(kind: .beforeDue, minutes: 30),
			rule(kind: .daysBefore, days: 1, hour: 12),
			rule(kind: .onDueDay, hour: 12),
			rule(kind: .beforeDue, minutes: 1440),
			rule(kind: .daysBefore, days: 7, hour: 12),
			rule(kind: .onDueDay, hour: 8),
			rule(kind: .daysBefore, days: 1, hour: 8),
		]

		let ordered = shuffled.sorted().map {
			(kind: $0.kind, days: $0.days, time: $0.time, minutes: $0.minutes)
		}

		#expect(
			ordered.map(\.kind) == [
				.daysBefore, .daysBefore, .daysBefore, .onDueDay, .onDueDay, .beforeDue, .beforeDue,
			]
		)
		// More days first, and on a tie the earlier time of day.
		#expect(ordered[0].days == 7)
		#expect(ordered[1].days == 1 && ordered[1].time == TimeOfDay(hour: 8, minute: 0))
		#expect(ordered[2].days == 1 && ordered[2].time == TimeOfDay(hour: 12, minute: 0))
		// On the due day, earlier first.
		#expect(ordered[3].time == TimeOfDay(hour: 8, minute: 0))
		#expect(ordered[4].time == TimeOfDay(hour: 12, minute: 0))
		// Before the deadline, the larger span first.
		#expect(ordered[5].minutes == 1440)
		#expect(ordered[6].minutes == 30)
	}
}
