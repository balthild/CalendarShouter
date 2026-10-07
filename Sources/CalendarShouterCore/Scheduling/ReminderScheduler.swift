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

	private let service: CalendarServicing
	private let settings: SettingsStore
	private let canvas: CanvasServicing?
	private let clock: Clock
	private let stateStore: ReminderStateStoring
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
		stateStore: ReminderStateStoring = UserDefaultsReminderStateStore.applicationDefault(),
		lookahead: TimeInterval = ReminderScheduler.defaultLookahead,
		lookback: TimeInterval = ReminderScheduler.defaultLookback
	) {
		self.service = service
		self.settings = settings
		self.canvas = canvas
		self.clock = clock
		self.stateStore = stateStore
		self.lookahead = lookahead
		self.lookback = lookback
		let state = stateStore.load()
		self.handledFireIDs = state.handledFireIDs
		self.lastEvaluationDate = state.lastEvaluationDate
		self.calendarActivationDates = state.calendarActivationDates
		self.knownEnabledCalendarIDs = settings.enabledCalendarIDs
		self.remindersActivationDate = state.remindersActivationDate
		self.knownIncludeReminders = settings.includeReminders
		self.acknowledgedTimes = state.acknowledgements
		self.snoozes = state.snoozes
		self.pendingFires = state.snoozes.map {
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
		persistState()
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

		pendingFires.removeAll { $0.isSnooze && $0.event.id == snoozed.event.id }
		pendingFires.append(snoozed)
		pendingFires.sort { $0.fireDate < $1.fireDate }
		scheduleNext()
		persistState()
	}

	/// Records that `fire` has been dealt with and will not be shown again.
	public func dismiss(_ fire: ReminderFire) {
		pendingFires.removeAll { $0.id == fire.id }
		if fire.isSnooze {
			snoozes.removeAll { $0.event.id == fire.event.id && $0.fireDate == fire.fireDate }
		} else {
			markHandled([fire.id])
		}
		recordAcknowledgement(eventID: fire.event.id, at: clock.now)
		scheduleNext()
		persistState()
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
		persistState()
	}

	// MARK: - Persisted bookkeeping

	private func markHandled(_ identifiers: [String]) {
		guard !identifiers.isEmpty else { return }
		handledFireIDs.formUnion(identifiers)
	}

	/// Remembers that the user dealt with `eventID`, so older alarms of the same
	/// event that were part of the same backlog stop asking for attention.
	private func recordAcknowledgement(eventID: String, at date: Date) {
		acknowledgedTimes[eventID] = date
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
		}
		let prunedAcks = acknowledgedTimes.filter { $0.value >= start }
		if prunedAcks.count != acknowledgedTimes.count {
			acknowledgedTimes = prunedAcks
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
			remindersActivationDate = nil
			return
		}
		guard becameEnabled else { return }
		remindersActivationDate = now
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
	}

	/// Called at the end of every entry point that changes bookkeeping, so the stored fields are
	/// always a consistent set. One that delivers due fires on the way through writes twice; the
	/// second snapshot is identical.
	private func persistState() {
		stateStore.save(
			ReminderState(
				handledFireIDs: handledFireIDs,
				lastEvaluationDate: lastEvaluationDate,
				calendarActivationDates: calendarActivationDates,
				remindersActivationDate: remindersActivationDate,
				acknowledgements: acknowledgedTimes,
				snoozes: snoozes
			)
		)
	}

	/// Extracts the fire instant encoded in a `ReminderFire` identifier.
	private static func fireDate(ofFireID fireID: String) -> Int? {
		// Event identifiers may themselves contain "@", so split on the last one.
		guard let separator = fireID.lastIndex(of: "@") else { return nil }
		return Int(fireID[fireID.index(after: separator)...])
	}
}
