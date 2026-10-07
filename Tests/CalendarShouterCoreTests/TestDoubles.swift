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

	/// Moves the clock forward without running any callback, modelling a machine that
	/// was asleep or an app that was closed: a scheduled timer does not fire.
	func jump(by interval: TimeInterval) {
		now = now.addingTimeInterval(interval)
	}
}

/// Calendar service backed by in-memory events and reminders.
@MainActor
final class FakeCalendarService: CalendarServicing {
	var authorization: CalendarAuthorization = .fullAccess
	var remindersAuthorization: CalendarAuthorization = .fullAccess
	var accounts: [CalendarAccount] = []
	var eventsToReturn: [ReminderEvent] = []
	var remindersToReturn: [ReminderEvent] = []
	private(set) var requestedRanges: [(start: Date, end: Date)] = []
	private(set) var requestedReminderRanges: [(start: Date, end: Date)] = []
	private(set) var refreshCount = 0

	func requestAccess() async -> Bool { true }

	func requestRemindersAccess() async -> Bool { true }

	func events(from startDate: Date, to endDate: Date) -> [ReminderEvent] {
		requestedRanges.append((startDate, endDate))
		return eventsToReturn.filter { event in
			event.fireDates.contains { $0 > startDate && $0 <= endDate }
		}
	}

	func reminders(from startDate: Date, to endDate: Date) -> [ReminderEvent] {
		requestedReminderRanges.append((startDate, endDate))
		return remindersToReturn.filter { reminder in
			reminder.fireDates.contains { $0 > startDate && $0 <= endDate }
		}
	}

	func refresh() { refreshCount += 1 }
}

/// Records the sign-in sessions the service asks to clear, without touching WebKit.
@MainActor
final class FakeCanvasWebSessions: CanvasWebSessionStoring {
	private(set) var discardedIdentifiers: [UUID] = []
	private(set) var reclaimRequests: [Set<UUID>] = []

	func discard(identifier: UUID) { discardedIdentifiers.append(identifier) }

	func discardUnclaimed(keeping identifiers: Set<UUID>) { reclaimRequests.append(identifiers) }
}

/// State store backed by memory, so a test that does not care where the bookkeeping lives never
/// has to make a `UserDefaults` suite.
final class InMemoryReminderStateStore: ReminderStateStoring {
	private(set) var state: ReminderState
	private(set) var saveCount = 0

	init(state: ReminderState = ReminderState()) {
		self.state = state
	}

	func load() -> ReminderState { state }

	func save(_ state: ReminderState) {
		self.state = state
		saveCount += 1
	}
}
