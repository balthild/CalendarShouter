import Foundation
import Testing

@testable import CalendarShouterCore

/// Deterministic `Clock` that only advances when a test says so.
@MainActor
final class FakeClock: Clock {
	private final class Task: ScheduledTask {
		var isCancelled = false
		func cancel() { isCancelled = true }
	}

	private struct Entry {
		let date: Date
		let task: Task
		let handler: ClockHandler
	}

	private(set) var now: Date
	private var entries: [Entry] = []

	init(now: Date) {
		self.now = now
	}

	/// The date of the earliest pending callback, if any.
	var nextScheduledDate: Date? {
		entries.filter { !$0.task.isCancelled }.map(\.date).min()
	}

	var hasPendingTasks: Bool {
		entries.contains { !$0.task.isCancelled }
	}

	func schedule(at date: Date, _ handler: @escaping ClockHandler) -> ScheduledTask {
		let task = Task()
		entries.append(Entry(date: date, task: task, handler: handler))
		return task
	}

	/// Moves the clock forward and runs every callback that is now due.
	func advance(by interval: TimeInterval) {
		let target = now.addingTimeInterval(interval)
		while let next = entries.filter({ !$0.task.isCancelled && $0.date <= target }).min(by: {
			$0.date < $1.date
		}) {
			entries.removeAll { $0.task === next.task }
			now = max(now, next.date)
			next.handler()
		}
		now = target
	}
}

/// Calendar service backed by in-memory events.
@MainActor
final class FakeCalendarService: CalendarServicing {
	var authorization: CalendarAuthorization = .fullAccess
	var accounts: [CalendarAccount] = []
	var eventsToReturn: [ReminderEvent] = []
	private(set) var requestedRanges: [(start: Date, end: Date)] = []
	private(set) var refreshCount = 0

	func requestAccess() async -> Bool { true }

	func events(from startDate: Date, to endDate: Date) -> [ReminderEvent] {
		requestedRanges.append((startDate, endDate))
		return eventsToReturn.filter { event in
			event.fireDates.contains { $0 > startDate && $0 <= endDate }
		}
	}

	func refresh() { refreshCount += 1 }
}
