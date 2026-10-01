import Foundation

/// Turns Canvas assignments into the reminder events the scheduler already understands.
///
/// Everything here is pure: it takes an assignment, the user's rules and a cutoff, and
/// returns instants. Fetching, caching and persistence live elsewhere, which keeps the
/// awkward parts of the rules testable without a network or a clock.
public enum CanvasReminderPlanner {
	/// The instants at which `assignment` should be shouted about.
	///
	/// A fire time is dropped silently when it falls outside the assignment's availability
	/// window, and when it predates the account being added. `calendar` supplies both the
	/// time zone the due *day* is judged in and the time zone the rules' times of day
	/// resolve against.
	public static func fireDates(
		for assignment: CanvasAssignment,
		rules: [CanvasReminderRule],
		calendar: Calendar = .current,
		notBefore cutoff: Date?
	) -> [Date] {
		guard assignment.canProduceReminders else { return [] }

		return
			rules
			.map(\.normalized)
			.compactMap { $0.fireDate(for: assignment, calendar: calendar) }
			.filter { fireDate in
				if let unlockAt = assignment.unlockAt, fireDate < unlockAt { return false }
				if let lockAt = assignment.lockAt, fireDate > lockAt { return false }
				if let cutoff, fireDate <= cutoff { return false }
				return true
			}
	}

	/// The assignment as a reminder event, carrying every fire instant the rules produce.
	///
	/// Returns nil when nothing is left to fire, so the scheduler is never handed an event
	/// that cannot do anything.
	public static func reminderEvent(
		for assignment: CanvasAssignment,
		account: CanvasAccount,
		rules: [CanvasReminderRule],
		calendar: Calendar = .current
	) -> ReminderEvent? {
		let fireDates = fireDates(
			for: assignment,
			rules: rules,
			calendar: calendar,
			notBefore: account.addedAt
		)
		guard !fireDates.isEmpty else { return nil }

		let dueAt = assignment.dueAt ?? account.addedAt
		return ReminderEvent(
			id: "canvas:\(assignment.id)",
			title: assignment.name,
			startDate: dueAt,
			endDate: dueAt,
			isAllDay: false,
			location: nil,
			notes: nil,
			calendar: CalendarInfo(
				id: assignment.course.id,
				title: assignment.course.name,
				color: CanvasPalette.courseColor,
				account: CalendarAccountRef(
					id: account.id,
					title: account.userName,
					kind: .other
				)
			),
			fireDates: fireDates.sorted()
		)
	}
}

extension CanvasReminderRule {
	/// When this rule wants the assignment shouted about, or nil when it cannot apply.
	public func fireDate(for assignment: CanvasAssignment, calendar: Calendar = .current) -> Date? {
		switch kind {
		case .daysBefore:
			guard let dueAt = assignment.dueAt else { return nil }
			guard
				let day = calendar.date(
					byAdding: .day,
					value: -max(0, days),
					to: calendar.startOfDay(for: dueAt)
				)
			else { return nil }
			return calendar.date(bySettingHour: time.hour, minute: time.minute, second: 0, of: day)

		case .onDueDay:
			guard let dueAt = assignment.dueAt else { return nil }
			let day = calendar.startOfDay(for: dueAt)
			return calendar.date(bySettingHour: time.hour, minute: time.minute, second: 0, of: day)

		case .beforeDue:
			guard let dueAt = assignment.dueAt else { return nil }
			return dueAt.addingTimeInterval(-Double(max(1, minutes)) * 60)
		}
	}
}
