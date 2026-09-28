import Foundation

/// A color expressed in the sRGB color space, so models stay free of AppKit types.
public struct RGBColor: Sendable, Equatable, Hashable {
	public let red: Double
	public let green: Double
	public let blue: Double
	public let alpha: Double

	public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
		self.red = red
		self.green = green
		self.blue = blue
		self.alpha = alpha
	}
}

/// The kind of account a calendar belongs to; mirrors EventKit's source types.
///
/// The raw values order the groups in the calendar list, local accounts first and the
/// system-supplied collections last.
public enum CalendarAccountKind: Int, Sendable, Comparable {
	case local = 0
	case exchange = 1
	case calDAV = 2
	case mobileMe = 3
	case subscribed = 4
	case birthdays = 5
	case other = 99

	public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Which account a calendar belongs to.
public struct CalendarAccountRef: Sendable, Equatable, Hashable {
	public let id: String
	public let title: String
	public let kind: CalendarAccountKind

	public init(id: String, title: String, kind: CalendarAccountKind) {
		self.id = id
		self.title = title
		self.kind = kind
	}
}

/// A calendar the app can read events from.
public struct CalendarInfo: Sendable, Identifiable, Equatable, Hashable {
	public let id: String
	public let title: String
	public let color: RGBColor
	public let account: CalendarAccountRef

	public init(id: String, title: String, color: RGBColor, account: CalendarAccountRef) {
		self.id = id
		self.title = title
		self.color = color
		self.account = account
	}
}

/// An account and the calendars it holds, as shown in the settings list.
public struct CalendarAccount: Sendable, Identifiable, Equatable {
	public let id: String
	public let title: String
	public let kind: CalendarAccountKind
	public let calendars: [CalendarInfo]

	public init(id: String, title: String, kind: CalendarAccountKind, calendars: [CalendarInfo]) {
		self.id = id
		self.title = title
		self.kind = kind
		self.calendars = calendars
	}

	/// Groups calendars by their account.
	///
	/// EventKit exposes no display order — the order the store returns is unrelated to the
	/// one the user set in the Calendar app — so groups are ordered by kind and then name,
	/// and calendars by name.
	public static func grouped(_ calendars: [CalendarInfo]) -> [CalendarAccount] {
		let byAccount = Dictionary(grouping: calendars, by: \.account.id)
		return
			byAccount
			.compactMap { _, calendars -> CalendarAccount? in
				guard let account = calendars.first?.account else { return nil }
				return CalendarAccount(
					id: account.id,
					title: account.title,
					kind: account.kind,
					calendars: calendars.sorted { lhs, rhs in
						lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
					}
				)
			}
			.sorted { lhs, rhs in
				if lhs.kind != rhs.kind { return lhs.kind < rhs.kind }
				return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
			}
	}
}

/// An event that carries at least one time-based alarm.
public struct ReminderEvent: Sendable, Identifiable, Equatable {
	public let id: String
	public let title: String
	public let startDate: Date
	public let endDate: Date
	public let isAllDay: Bool
	public let location: String?
	public let notes: String?
	public let calendar: CalendarInfo
	/// The instants at which this event's own alarms should fire.
	public let fireDates: [Date]
	public init(
		id: String,
		title: String,
		startDate: Date,
		endDate: Date,
		isAllDay: Bool,
		location: String?,
		notes: String?,
		calendar: CalendarInfo,
		fireDates: [Date]
	) {
		self.id = id
		self.title = title
		self.startDate = startDate
		self.endDate = endDate
		self.isAllDay = isAllDay
		self.location = location
		self.notes = notes
		self.calendar = calendar
		self.fireDates = fireDates
	}
}

/// A single reminder to present to the user.
public struct ReminderFire: Sendable, Identifiable, Equatable {
	public let event: ReminderEvent
	public let fireDate: Date
	/// Whether this reminder was created by the user's "snooze" action.
	public let isSnooze: Bool

	/// A stable identity that is unique per event *and* per fire time, so that
	/// snoozing an event produces a distinct reminder from the original.
	public var id: String {
		"\(event.id)@\(Int(fireDate.timeIntervalSince1970))"
	}

	public init(event: ReminderEvent, fireDate: Date, isSnooze: Bool) {
		self.event = event
		self.fireDate = fireDate
		self.isSnooze = isSnooze
	}
}
