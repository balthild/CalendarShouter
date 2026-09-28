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
	}

	private let defaults: UserDefaults

	public var showMenuBarIcon: Bool {
		didSet { defaults.set(showMenuBarIcon, forKey: Key.showMenuBarIcon) }
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
