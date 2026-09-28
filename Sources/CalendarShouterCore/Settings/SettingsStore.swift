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
		static let soundName = "soundName"
		static let showMissedReminders = "showMissedReminders"
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

	/// An empty name means silence.
	public var soundName: String {
		didSet { defaults.set(soundName, forKey: Key.soundName) }
	}

	public init(defaults: UserDefaults = .standard) {
		self.defaults = defaults
		self.showMenuBarIcon = defaults.object(forKey: Key.showMenuBarIcon) as? Bool ?? true
		self.showMissedReminders = defaults.object(forKey: Key.showMissedReminders) as? Bool ?? true
		self.enabledCalendarIDs = Set(defaults.stringArray(forKey: Key.enabledCalendarIDs) ?? [])
		self.soundName = defaults.string(forKey: Key.soundName) ?? Self.defaultSoundName
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
}
