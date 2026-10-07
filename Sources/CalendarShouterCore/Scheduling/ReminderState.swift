import Foundation

/// Everything the scheduler remembers between launches.
///
/// None of it is a source of truth: every field can be rebuilt from EventKit and the user's
/// settings. It is kept as one value so that a single write replaces the whole snapshot, and a
/// crash can never leave the fields disagreeing with each other.
public struct ReminderState: Codable, Equatable, Sendable {
	public var handledFireIDs: Set<String>
	public var lastEvaluationDate: Date?
	public var calendarActivationDates: [String: Date]
	public var remindersActivationDate: Date?
	public var acknowledgements: [String: Date]
	public var snoozes: [PersistedSnooze]

	public init(
		handledFireIDs: Set<String> = [],
		lastEvaluationDate: Date? = nil,
		calendarActivationDates: [String: Date] = [:],
		remindersActivationDate: Date? = nil,
		acknowledgements: [String: Date] = [:],
		snoozes: [PersistedSnooze] = []
	) {
		self.handledFireIDs = handledFireIDs
		self.lastEvaluationDate = lastEvaluationDate
		self.calendarActivationDates = calendarActivationDates
		self.remindersActivationDate = remindersActivationDate
		self.acknowledgements = acknowledgements
		self.snoozes = snoozes
	}
}

/// A snoozed reminder, persisted so it survives a relaunch.
public struct PersistedSnooze: Codable, Equatable, Sendable {
	public let event: ReminderEvent
	public let fireDate: Date

	public init(event: ReminderEvent, fireDate: Date) {
		self.event = event
		self.fireDate = fireDate
	}
}

/// Where the scheduler keeps its bookkeeping.
///
/// The backend is a detail: the scheduler only ever loads one snapshot and saves one back. That
/// is what makes the storage replaceable without touching the scheduling logic.
public protocol ReminderStateStoring {
	/// The last saved state, or an empty one when nothing has been saved.
	func load() -> ReminderState
	func save(_ state: ReminderState)
}

/// Bookkeeping in its own `UserDefaults` suite, under a single key.
///
/// Keeping it out of the settings domain means "what the user chose" and "what the scheduler has
/// already shown" cannot damage each other: the bookkeeping can be dropped without touching a
/// preference, and a corrupted preference cannot take the bookkeeping with it. `PersistedJSON`
/// supplies the same keep-aside-on-decode-failure behaviour the settings domain uses.
public struct UserDefaultsReminderStateStore: ReminderStateStoring {
	/// The suite the bookkeeping lives in.
	public static let appSuiteName = "com.balthild.CalendarShouter.state"
	public static let defaultKey = "reminderState"

	private let defaults: UserDefaults
	private let key: String

	public init(defaults: UserDefaults, key: String = UserDefaultsReminderStateStore.defaultKey) {
		self.defaults = defaults
		self.key = key
	}

	/// The store the app runs on.
	///
	/// A suite that cannot be created is not a reason to lose reminders, so the settings domain
	/// is used instead: isolation is traded for the app still working.
	public static func applicationDefault() -> UserDefaultsReminderStateStore {
		UserDefaultsReminderStateStore(defaults: UserDefaults(suiteName: appSuiteName) ?? .standard)
	}

	public func load() -> ReminderState {
		PersistedJSON.value(ReminderState.self, forKey: key, in: defaults) ?? ReminderState()
	}

	public func save(_ state: ReminderState) {
		PersistedJSON.set(state, forKey: key, in: defaults)
	}

	/// The keys the scheduler used to write straight into the settings domain.
	///
	/// Nothing reads them any more. They are removed so that "the bookkeeping is not a
	/// preference" is true of the plist too, rather than only of the code.
	public static func removeLegacyKeys(from defaults: UserDefaults) {
		for key in legacyKeys {
			defaults.removeObject(forKey: key)
		}
	}

	private static let legacyKeys = [
		"handledFireIDs",
		"schedulerLastEvaluationDate",
		"calendarActivationDates",
		"reminderAcknowledgementTimes",
		"snoozedReminders",
		"remindersActivationDate",
	]
}
