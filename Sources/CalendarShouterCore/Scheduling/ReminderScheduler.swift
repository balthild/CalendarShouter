import Foundation

/// Turns an event's alarms into reminder firings.
///
/// The scheduler fetches a window of upcoming events, expands each event's alarms
/// into individual firings, remembers which have already been shown, and holds a
/// single timer for the next one due.
@MainActor
public final class ReminderScheduler {
	/// How far ahead the scheduler looks for alarms.
	public static let defaultLookahead: TimeInterval = 7 * 24 * 60 * 60

	/// Alarms that fired slightly before the app started are still shown, but
	/// anything older is treated as missed so a relaunch does not replay history.
	private static let missedGraceInterval: TimeInterval = 60

	private enum Key {
		static let handledFireIDs = "handledFireIDs"
	}

	private let service: CalendarServicing
	private let settings: SettingsStore
	private let clock: Clock
	private let defaults: UserDefaults
	private let lookahead: TimeInterval

	/// Called with every reminder that becomes due, in chronological order.
	public var onFire: (([ReminderFire]) -> Void)?

	private var pendingFires: [ReminderFire] = []
	private var scheduledTask: ScheduledTask?
	private var handledFireIDs: Set<String>

	public init(
		service: CalendarServicing,
		settings: SettingsStore,
		clock: Clock = SystemClock(),
		defaults: UserDefaults = .standard,
		lookahead: TimeInterval = ReminderScheduler.defaultLookahead
	) {
		self.service = service
		self.settings = settings
		self.clock = clock
		self.defaults = defaults
		self.lookahead = lookahead
		self.handledFireIDs = Set(defaults.stringArray(forKey: Key.handledFireIDs) ?? [])
	}

	/// The reminders currently waiting to be shown, in chronological order.
	public var upcomingFires: [ReminderFire] { pendingFires }

	/// Re-reads the calendar and rebuilds the pending reminders.
	public func reload() {
		let now = clock.now
		let windowStart = now.addingTimeInterval(-Self.missedGraceInterval)
		let windowEnd = now.addingTimeInterval(lookahead)

		pruneHandledFireIDs(keepingFrom: windowStart)

		let eventFires = service.events(from: windowStart, to: windowEnd)
			.filter { settings.isReminderEnabled(forCalendarID: $0.calendar.id) }
			.flatMap { event in
				event.fireDates
					.filter { $0 > windowStart && $0 <= windowEnd }
					.map { fireDate in
						ReminderFire(event: event, fireDate: fireDate, isSnooze: false)
					}
			}
			.filter { !handledFireIDs.contains($0.id) }

		pendingFires = (eventFires + pendingFires.filter(\.isSnooze))
			.sorted { $0.fireDate < $1.fireDate }
		scheduleNext()
	}

	/// Schedules `fire` to be shown again after `option`'s delay.
	public func snooze(_ fire: ReminderFire, by option: SnoozeOption) {
		let snoozed = ReminderFire(
			event: fire.event,
			fireDate: clock.now.addingTimeInterval(option.timeInterval),
			isSnooze: true
		)
		pendingFires.removeAll { $0.id == snoozed.id }
		pendingFires.append(snoozed)
		pendingFires.sort { $0.fireDate < $1.fireDate }
		scheduleNext()
	}

	/// Records that `fire` has been dealt with and will not be shown again.
	public func dismiss(_ fire: ReminderFire) {
		pendingFires.removeAll { $0.id == fire.id }
		if !fire.isSnooze {
			markHandled([fire.id])
		}
		scheduleNext()
	}

	// MARK: - Timer management

	private func scheduleNext() {
		scheduledTask?.cancel()
		scheduledTask = nil

		guard let next = pendingFires.first else { return }
		guard next.fireDate > clock.now else {
			deliverDueFires()
			return
		}
		scheduledTask = clock.schedule(at: next.fireDate) { [weak self] in
			self?.deliverDueFires()
		}
	}

	private func deliverDueFires() {
		let now = clock.now
		let due = pendingFires.filter { $0.fireDate <= now }
		guard !due.isEmpty else {
			scheduleNext()
			return
		}

		let dueIDs = Set(due.map(\.id))
		pendingFires.removeAll { dueIDs.contains($0.id) }
		markHandled(due.filter { !$0.isSnooze }.map(\.id))
		onFire?(due)
		scheduleNext()
	}

	// MARK: - Persisted bookkeeping

	private func markHandled(_ identifiers: [String]) {
		guard !identifiers.isEmpty else { return }
		handledFireIDs.formUnion(identifiers)
		persistHandledFireIDs()
	}

	private func pruneHandledFireIDs(keepingFrom date: Date) {
		let threshold = Int(date.timeIntervalSince1970)
		let pruned = handledFireIDs.filter { fireID in
			guard let timestamp = Self.fireDate(ofFireID: fireID) else { return false }
			return timestamp >= threshold
		}
		guard pruned.count != handledFireIDs.count else { return }
		handledFireIDs = pruned
		persistHandledFireIDs()
	}

	private func persistHandledFireIDs() {
		defaults.set(handledFireIDs.sorted(), forKey: Key.handledFireIDs)
	}

	/// Extracts the fire instant encoded in a `ReminderFire` identifier.
	private static func fireDate(ofFireID fireID: String) -> Int? {
		// Event identifiers may themselves contain "@", so split on the last one.
		guard let separator = fireID.lastIndex(of: "@") else { return nil }
		return Int(fireID[fireID.index(after: separator)...])
	}
}
