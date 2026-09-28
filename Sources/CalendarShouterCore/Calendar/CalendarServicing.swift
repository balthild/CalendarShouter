import Foundation

/// The app's level of access to a protected store: the user's calendars or reminders.
public enum CalendarAuthorization: Sendable, Equatable {
	case notDetermined
	case denied
	case restricted
	case writeOnly
	case fullAccess

	/// Whether events can be read with this level of access.
	public var canReadEvents: Bool { self == .fullAccess }

	/// Whether reminders can be read with this level of access.
	///
	/// Reminders have no write-only level, but the statuses are shared so both
	/// permissions can be handled through the same type.
	public var canReadReminders: Bool { self == .fullAccess }

	/// Whether the user can still be asked for access.
	public var isUndetermined: Bool { self == .notDetermined }
}

/// Read access to the user's calendars and reminders.
///
/// Deliberately free of observation machinery so tests can substitute a fake; the concrete
/// EventKit-backed service is `@Observable` and is what the SwiftUI layer binds to.
@MainActor
public protocol CalendarServicing: AnyObject {
	/// The current level of access to the user's calendars.
	var authorization: CalendarAuthorization { get }
	/// The current level of access to the user's reminders.
	var remindersAuthorization: CalendarAuthorization { get }
	/// The calendars available to read, grouped by account.
	var accounts: [CalendarAccount] { get }
	/// Asks the user for access to their calendars, returning whether it was granted.
	func requestAccess() async -> Bool
	/// Asks the user for access to their reminders, returning whether it was granted.
	func requestRemindersAccess() async -> Bool
	/// Returns every event in the range that carries a time-based alarm.
	func events(from startDate: Date, to endDate: Date) -> [ReminderEvent]
	/// Returns every reminder in the range that carries a time to shout at.
	func reminders(from startDate: Date, to endDate: Date) -> [ReminderEvent]
	/// Re-reads the authorization status and calendar list.
	func refresh()
}
