import Foundation

/// The app's level of access to the user's calendars.
public enum CalendarAuthorization: Sendable, Equatable {
	case notDetermined
	case denied
	case restricted
	case writeOnly
	case fullAccess

	/// Whether events can be read with this level of access.
	public var canReadEvents: Bool { self == .fullAccess }

	/// Whether the user can still be asked for access.
	public var isUndetermined: Bool { self == .notDetermined }
}

/// Read access to the user's calendars.
///
/// Deliberately free of observation machinery so tests can substitute a fake; the concrete
/// EventKit-backed service is `@Observable` and is what the SwiftUI layer binds to.
@MainActor
public protocol CalendarServicing: AnyObject {
	/// The current level of access.
	var authorization: CalendarAuthorization { get }
	/// The calendars available to read, grouped by account.
	var accounts: [CalendarAccount] { get }
	/// Asks the user for access, returning whether it was granted.
	func requestAccess() async -> Bool
	/// Returns every event in the range that carries a time-based alarm.
	func events(from startDate: Date, to endDate: Date) -> [ReminderEvent]
	/// Re-reads the authorization status and calendar list.
	func refresh()
}
