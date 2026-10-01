import Foundation
import Observation

/// User-configurable preferences, persisted in `UserDefaults`.
@MainActor
@Observable
public final class SettingsStore {
	/// The system sound used before the user makes an explicit choice.
	public static let defaultSoundName = "Glass"

	private enum Key {
		static let showMenuBarIcon = "showMenuBarIcon"
		static let enabledCalendarIDs = "enabledCalendarIDs"
		static let includeReminders = "includeReminders"
		static let soundName = "soundName"
		static let showMissedReminders = "showMissedReminders"
		static let canvasAccounts = "canvasAccounts"
		static let canvasReminderRules = "canvasReminderRules"
		static let enabledCanvasCourseIDs = "enabledCanvasCourseIDs"
	}

	private let defaults: UserDefaults

	public var showMenuBarIcon: Bool {
		didSet { defaults.set(showMenuBarIcon, forKey: Key.showMenuBarIcon) }
	}

	/// Whether reminders that came due while the app was asleep or closed are shown
	/// once it is watching again.
	///
	/// On by default: a reminder that arrives late is still worth seeing, and this
	/// app is meant for people who need to be told what they have missed.
	public var showMissedReminders: Bool {
		didSet { defaults.set(showMissedReminders, forKey: Key.showMissedReminders) }
	}

	/// Calendars the user has switched on.
	///
	/// Storing the *included* set means a calendar has to be opted into before it can
	/// produce reminders, and a calendar added later starts switched off as well. This
	/// is deliberately the conservative way round: a reminder interrupts whatever the
	/// user is doing, so silence is the safer default.
	public var enabledCalendarIDs: Set<String> {
		didSet { defaults.set(enabledCalendarIDs.sorted(), forKey: Key.enabledCalendarIDs) }
	}

	/// Whether reminders from the system Reminders app are shouted about as well.
	///
	/// Unlike calendar selection this is a single switch covering every reminder list;
	/// there is no per-list allow-list. On by default, so reminders work out of the box
	/// alongside the calendars the user opts into.
	public var includeReminders: Bool {
		didSet { defaults.set(includeReminders, forKey: Key.includeReminders) }
	}

	/// An empty name means silence.
	public var soundName: String {
		didSet { defaults.set(soundName, forKey: Key.soundName) }
	}

	/// The Canvas accounts the user has signed in to.
	///
	/// The credentials that go with each account are *not* here; those live in the keychain.
	public var canvasAccounts: [CanvasAccount] {
		didSet { persist(canvasAccounts, forKey: Key.canvasAccounts) }
	}

	/// The rules that turn an assignment's due date into reminder times.
	///
	/// Unlike calendar selection these are not per course: one list applies to every course
	/// of every account.
	public var canvasReminderRules: [CanvasReminderRule] {
		didSet { persist(canvasReminderRules, forKey: Key.canvasReminderRules) }
	}

	/// Canvas courses the user has switched on.
	///
	/// An allow-list kept separate from `enabledCalendarIDs`, so the calendar pane's
	/// selections and the Canvas pane's cannot be confused for one another.
	public var enabledCanvasCourseIDs: Set<String> {
		didSet { defaults.set(enabledCanvasCourseIDs.sorted(), forKey: Key.enabledCanvasCourseIDs) }
	}

	public init(defaults: UserDefaults = .standard) {
		self.defaults = defaults
		self.showMenuBarIcon = defaults.object(forKey: Key.showMenuBarIcon) as? Bool ?? true
		self.showMissedReminders = defaults.object(forKey: Key.showMissedReminders) as? Bool ?? true
		self.enabledCalendarIDs = Set(defaults.stringArray(forKey: Key.enabledCalendarIDs) ?? [])
		self.includeReminders = defaults.object(forKey: Key.includeReminders) as? Bool ?? true
		self.soundName = defaults.string(forKey: Key.soundName) ?? Self.defaultSoundName
		self.canvasAccounts =
			Self.decode([CanvasAccount].self, from: defaults, Key.canvasAccounts) ?? []
		self.canvasReminderRules =
			Self.decode([CanvasReminderRule].self, from: defaults, Key.canvasReminderRules) ?? []
		self.enabledCanvasCourseIDs = Set(
			defaults.stringArray(forKey: Key.enabledCanvasCourseIDs) ?? []
		)
	}

	public func isReminderEnabled(forCalendarID identifier: String) -> Bool {
		enabledCalendarIDs.contains(identifier)
	}

	public func setReminderEnabled(_ enabled: Bool, forCalendarID identifier: String) {
		if enabled {
			enabledCalendarIDs.insert(identifier)
		} else {
			enabledCalendarIDs.remove(identifier)
		}
	}

	public func isCanvasReminderEnabled(forCourseID identifier: String) -> Bool {
		enabledCanvasCourseIDs.contains(identifier)
	}

	public func setCanvasReminderEnabled(_ enabled: Bool, forCourseID identifier: String) {
		if enabled {
			enabledCanvasCourseIDs.insert(identifier)
		} else {
			enabledCanvasCourseIDs.remove(identifier)
		}
	}

	/// Drops the enablement records for courses that no longer exist.
	public func pruneCanvasCourseSelection(keeping identifiers: Set<String>) {
		let pruned = enabledCanvasCourseIDs.intersection(identifiers)
		guard pruned != enabledCanvasCourseIDs else { return }
		enabledCanvasCourseIDs = pruned
	}

	private func persist<T: Encodable>(_ value: T, forKey key: String) {
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
}
