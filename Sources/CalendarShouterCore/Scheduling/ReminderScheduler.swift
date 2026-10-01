import Foundation

/// Turns events' and reminders' alarms into reminder firings.
///
/// The scheduler fetches a window of events and the user's reminders, expands each item's
/// alarms into individual firings, remembers which have already been shown, and holds a
/// single timer for the next one due. Alarms that came due while the app was asleep or closed
/// are replayed as missed reminders, guarded so that neither a newly enabled calendar nor an
/// already acknowledged item floods the user.
@MainActor
public final class ReminderScheduler {
	/// How far ahead the scheduler looks for alarms.
	public static let defaultLookahead: TimeInterval = 7 * 24 * 60 * 60

	/// The furthest back a missed reminder is ever replayed, so a machine left off
	/// for months does not surface an unbounded backlog.
	public static let defaultLookback: TimeInterval = 30 * 24 * 60 * 60

	/// Alarms that fired slightly before the app last looked are still shown, but
	/// anything older is treated as missed.
	private static let missedGraceInterval: TimeInterval = 60

	private enum Key {
		static let handledFireIDs = "handledFireIDs"
		static let lastEvaluationDate = "schedulerLastEvaluationDate"
		static let calendarActivationDates = "calendarActivationDates"
		static let acknowledgedTimes = "reminderAcknowledgementTimes"
		static let snoozedReminders = "snoozedReminders"
		static let remindersActivationDate = "remindersActivationDate"
	}

	/// A snoozed reminder, persisted so it survives a relaunch.
	private struct PersistedSnooze: Codable {
		let event: ReminderEvent
		let fireDate: Date
	}

	private let service: CalendarServicing
	private let settings: SettingsStore
	private let canvas: CanvasServicing?
	private let clock: Clock
	private let defaults: UserDefaults
	private let lookahead: TimeInterval
	private let lookback: TimeInterval

	/// Called with every reminder that becomes due, in chronological order.
	public var onFire: (([ReminderFire]) -> Void)?

	private var pendingFires: [ReminderFire] = []
	private var scheduledTask: ScheduledTask?
	private var handledFireIDs: Set<String>
	private var lastEvaluationDate: Date?
	private var calendarActivationDates: [String: Date]
	private var knownEnabledCalendarIDs: Set<String>
	/// When the user most recently switched reminders on, so their history is not replayed.
	private var remindersActivationDate: Date?
	private var knownIncludeReminders: Bool
	private var acknowledgedTimes: [String: Date]
	private var snoozes: [PersistedSnooze]

	public init(
		service: CalendarServicing,
		settings: SettingsStore,
		canvas: CanvasServicing? = nil,
		clock: Clock = SystemClock(),
		defaults: UserDefaults = .standard,
		lookahead: TimeInterval = ReminderScheduler.defaultLookahead,
		lookback: TimeInterval = ReminderScheduler.defaultLookback
	) {
		self.service = service
		self.settings = settings
		self.canvas = canvas
		self.clock = clock
		self.defaults = defaults
		self.lookahead = lookahead
		self.lookback = lookback
		self.handledFireIDs = Set(defaults.stringArray(forKey: Key.handledFireIDs) ?? [])
		self.lastEvaluationDate = defaults.object(forKey: Key.lastEvaluationDate) as? Date
		self.calendarActivationDates =
			Self.decode([String: Date].self, from: defaults, Key.calendarActivationDates) ?? [:]
		self.knownEnabledCalendarIDs = settings.enabledCalendarIDs
		self.remindersActivationDate = defaults.object(forKey: Key.remindersActivationDate) as? Date
		self.knownIncludeReminders = settings.includeReminders
		self.acknowledgedTimes =
			Self.decode([String: Date].self, from: defaults, Key.acknowledgedTimes) ?? [:]
		let snoozes = Self.decode([PersistedSnooze].self, from: defaults, Key.snoozedReminders) ?? []
		self.snoozes = snoozes
		self.pendingFires = snoozes.map {
			ReminderFire(event: $0.event, fireDate: $0.fireDate, isSnooze: true)
		}
	}

	/// The reminders currently waiting to be shown, in chronological order.
	public var upcomingFires: [ReminderFire] { pendingFires }

	/// Re-reads the calendar and rebuilds the pending reminders.
	public func reload() {
		let now = clock.now
		let windowStart = evaluationStart(now: now)
		let windowEnd = now.addingTimeInterval(lookahead)

		lastEvaluationDate = now
		defaults.set(now, forKey: Key.lastEvaluationDate)

		pruneBookkeeping(from: windowStart, to: windowEnd)
		updateCalendarActivations(now: now)
		updateReminderActivation(now: now)

		let eventFires = fires(
			from: service.events(from: windowStart, to: windowEnd),
			windowStart: windowStart,
			windowEnd: windowEnd,
			now: now,
			isEnabled: { self.settings.isReminderEnabled(forCalendarID: $0.calendar.id) },
			isAfterActivation: { event, fireDate in
				self.isAfterActivation(fireDate, calendarID: event.calendar.id)
			}
		)
		// Reminders are all-or-nothing: there is no per-list selection to filter on.
		let reminderFires =
			settings.includeReminders
			? fires(
				from: service.reminders(from: windowStart, to: windowEnd),
				windowStart: windowStart,
				windowEnd: windowEnd,
				now: now,
				isEnabled: { _ in true },
				isAfterActivation: { _, fireDate in self.isAfterReminderActivation(fireDate) }
			)
			: []

		// Canvas assignments have no alarms of their own; their fire times are derived from
		// the user's rules, and each account's own add time bounds what may be replayed.
		let canvasFires = fires(
			from: canvas?.reminders(from: windowStart, to: windowEnd) ?? [],
			windowStart: windowStart,
			windowEnd: windowEnd,
			now: now,
			isEnabled: { self.settings.isCanvasReminderEnabled(forCourseID: $0.calendar.id) },
			isAfterActivation: { _, _ in true }
		)

		pendingFires = (eventFires + reminderFires + canvasFires + snoozes.map { self.fire(for: $0) })
			.sorted { $0.fireDate < $1.fireDate }
		scheduleNext()
	}

	/// Expands a set of items' alarm times into firings, dropping the ones already dealt
	/// with and the ones their source does not currently allow.
	private func fires(
		from items: [ReminderEvent],
		windowStart: Date,
		windowEnd: Date,
		now: Date,
		isEnabled: (ReminderEvent) -> Bool,
		isAfterActivation: (ReminderEvent, Date) -> Bool
	) -> [ReminderFire] {
		items
			.filter(isEnabled)
			.flatMap { item in
				item.fireDates
					.filter { $0 > windowStart && $0 <= windowEnd }
					.filter { isAfterActivation(item, $0) }
					.filter { self.isUnacknowledged($0, eventID: item.id) }
					.map { fireDate in
						ReminderFire(
							event: item,
							fireDate: fireDate,
							isSnooze: false,
							isLate: fireDate < now.addingTimeInterval(-Self.missedGraceInterval)
						)
					}
			}
			.filter { !handledFireIDs.contains($0.id) }
	}

	/// How far back this evaluation looks.
	///
	/// Ordinarily just the grace window. When missed reminders are shown the window
	/// reaches back to the previous evaluation, so a sleep or a relaunch replays the
	/// gap, bounded by `lookback`.
	private func evaluationStart(now: Date) -> Date {
		var start = now.addingTimeInterval(-Self.missedGraceInterval)
		if settings.showMissedReminders, let lastEvaluationDate {
			start = min(start, lastEvaluationDate)
		}
		return max(start, now.addingTimeInterval(-lookback))
	}

	/// Schedules `fire` to be shown again after `option`'s delay.
	public func snooze(_ fire: ReminderFire, by option: SnoozeOption) {
		let now = clock.now
		let snoozed = ReminderFire(
			event: fire.event,
			fireDate: now.addingTimeInterval(option.timeInterval),
			isSnooze: true
		)
		recordAcknowledgement(eventID: fire.event.id, at: now)

		snoozes.removeAll { $0.event.id == snoozed.event.id }
		snoozes.append(PersistedSnooze(event: snoozed.event, fireDate: snoozed.fireDate))
		persistSnoozes()

		pendingFires.removeAll { $0.isSnooze && $0.event.id == snoozed.event.id }
		pendingFires.append(snoozed)
		pendingFires.sort { $0.fireDate < $1.fireDate }
		scheduleNext()
	}

	/// Records that `fire` has been dealt with and will not be shown again.
	public func dismiss(_ fire: ReminderFire) {
		pendingFires.removeAll { $0.id == fire.id }
		if fire.isSnooze {
			snoozes.removeAll { $0.event.id == fire.event.id && $0.fireDate == fire.fireDate }
			persistSnoozes()
		} else {
			markHandled([fire.id])
		}
		recordAcknowledgement(eventID: fire.event.id, at: clock.now)
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
		removeDeliveredSnoozes(due)
		onFire?(due)
		scheduleNext()
	}

	// MARK: - Persisted bookkeeping

	private func markHandled(_ identifiers: [String]) {
		guard !identifiers.isEmpty else { return }
		handledFireIDs.formUnion(identifiers)
		persistHandledFireIDs()
	}

	/// Remembers that the user dealt with `eventID`, so older alarms of the same
	/// event that were part of the same backlog stop asking for attention.
	private func recordAcknowledgement(eventID: String, at date: Date) {
		acknowledgedTimes[eventID] = date
		persist(acknowledgedTimes, Key.acknowledgedTimes)
		pendingFires.removeAll { fire in
			guard !fire.isSnooze, fire.event.id == eventID else { return false }
			return fire.fireDate <= date
		}
	}

	/// Drops bookkeeping for alarms that can no longer be evaluated.
	private func pruneBookkeeping(from start: Date, to end: Date) {
		let lower = Int(start.timeIntervalSince1970)
		let upper = Int(end.timeIntervalSince1970)
		let prunedHandled = handledFireIDs.filter { fireID in
			guard let timestamp = Self.fireDate(ofFireID: fireID) else { return false }
			return timestamp >= lower && timestamp <= upper
		}
		if prunedHandled.count != handledFireIDs.count {
			handledFireIDs = prunedHandled
			persistHandledFireIDs()
		}
		let prunedAcks = acknowledgedTimes.filter { $0.value >= start }
		if prunedAcks.count != acknowledgedTimes.count {
			acknowledgedTimes = prunedAcks
			persist(acknowledgedTimes, Key.acknowledgedTimes)
		}
	}

	/// Stamps calendars that have just been switched on, so their history is not
	/// replayed when they start producing reminders, while leaving calendars that
	/// were already enabled alone.
	private func updateCalendarActivations(now: Date) {
		let enabled = settings.enabledCalendarIDs
		let newlyEnabled = enabled.subtracting(knownEnabledCalendarIDs)
		knownEnabledCalendarIDs = enabled

		var updated = calendarActivationDates.filter { enabled.contains($0.key) }
		for identifier in newlyEnabled {
			updated[identifier] = now
		}
		guard updated != calendarActivationDates else { return }
		calendarActivationDates = updated
		persist(calendarActivationDates, Key.calendarActivationDates)
	}

	/// A calendar only suppresses history once it has been switched on at runtime;
	/// one that was already enabled has no stamp and imposes no restriction.
	private func isAfterActivation(_ fireDate: Date, calendarID: String) -> Bool {
		fireDate > (calendarActivationDates[calendarID] ?? .distantPast)
	}

	/// Stamps the moment reminders are switched on, so their history is not replayed the
	/// first time they start producing reminders. Turning them off forgets the stamp, so
	/// switching them back on starts a fresh window.
	private func updateReminderActivation(now: Date) {
		let enabled = settings.includeReminders
		let becameEnabled = enabled && !knownIncludeReminders
		knownIncludeReminders = enabled

		if !enabled {
			guard remindersActivationDate != nil else { return }
			remindersActivationDate = nil
			defaults.removeObject(forKey: Key.remindersActivationDate)
			return
		}
		guard becameEnabled else { return }
		remindersActivationDate = now
		defaults.set(now, forKey: Key.remindersActivationDate)
	}

	/// Reminders only suppress history once they have been switched on at runtime; when they
	/// have been on all along there is no stamp and no restriction.
	private func isAfterReminderActivation(_ fireDate: Date) -> Bool {
		fireDate > (remindersActivationDate ?? .distantPast)
	}

	private func isUnacknowledged(_ fireDate: Date, eventID: String) -> Bool {
		(acknowledgedTimes[eventID] ?? .distantPast) < fireDate
	}

	private func fire(for snooze: PersistedSnooze) -> ReminderFire {
		ReminderFire(event: snooze.event, fireDate: snooze.fireDate, isSnooze: true)
	}

	private func removeDeliveredSnoozes(_ fires: [ReminderFire]) {
		let delivered = fires.filter(\.isSnooze)
		guard !delivered.isEmpty else { return }
		snoozes.removeAll { snooze in
			delivered.contains { $0.event.id == snooze.event.id && $0.fireDate == snooze.fireDate }
		}
		persistSnoozes()
	}

	private func persistSnoozes() {
		persist(snoozes, Key.snoozedReminders)
	}

	private func persistHandledFireIDs() {
		defaults.set(handledFireIDs.sorted(), forKey: Key.handledFireIDs)
	}

	private func persist<T: Encodable>(_ value: T, _ key: String) {
		guard let data = try? JSONEncoder().encode(value) else { return }
		defaults.set(data, forKey: key)
	}

	private static func decode<T: Decodable>(
		_ type: T.Type,
		from defaults: UserDefaults,
		_ key: String
	) -> T? {
		guard let data = defaults.data(forKey: key) else { return nil }
		return try? JSONDecoder().decode(type, from: data)
	}

	/// Extracts the fire instant encoded in a `ReminderFire` identifier.
	private static func fireDate(ofFireID fireID: String) -> Int? {
		// Event identifiers may themselves contain "@", so split on the last one.
		guard let separator = fireID.lastIndex(of: "@") else { return nil }
		return Int(fireID[fireID.index(after: separator)...])
	}
}
