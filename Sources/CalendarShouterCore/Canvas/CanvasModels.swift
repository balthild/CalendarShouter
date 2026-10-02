import Foundation

/// A Canvas account the user has signed in to.
///
/// The OAuth client credentials are deliberately absent: they are fetched per domain at
/// sign-in time and belong in the keychain, not in a preferences file.
public struct CanvasAccount: Sendable, Identifiable, Equatable, Codable {
	public let id: String
	/// The host the account lives on, as the user typed it (e.g. `canvas.school.edu`).
	public let domain: String
	/// The URL Canvas reports for API calls; it can differ from `domain` by scheme or host.
	public let baseURL: URL
	public let userID: String
	public let userName: String
	/// When the account was added.
	///
	/// Nothing that falls due before this is replayed, so signing in does not immediately
	/// shout about every assignment the account has ever had.
	public let addedAt: Date

	/// The browser session this account signs in with.
	///
	/// Every account has one, including accounts stored before the field existed: `@Fallback`
	/// hands those a new identifier rather than failing the decode, since a missing key would
	/// otherwise take the whole account list down with it. The cost is that such an account
	/// starts with an empty session, so its next sign-in asks for a password instead of
	/// reusing the shared store it used to sign in through. Worth it: before this field, two
	/// accounts on one domain shared that store.
	@Fallback<NewWebSessionIdentifier>
	public var storeIdentifier: UUID

	public init(
		id: String,
		domain: String,
		baseURL: URL,
		userID: String,
		userName: String,
		addedAt: Date,
		storeIdentifier: UUID = UUID()
	) {
		self.id = id
		self.domain = domain
		self.baseURL = baseURL
		self.userID = userID
		self.userName = userName
		self.addedAt = addedAt
		self.storeIdentifier = storeIdentifier
	}
}

/// A course within a Canvas account.
public struct CanvasCourse: Sendable, Identifiable, Equatable, Codable {
	/// Namespaced as `<account id>:<course id>` so courses from different accounts cannot clash.
	public let id: String
	/// Canvas's own course id, as used in API paths.
	public let courseID: String
	public let accountID: String
	public let name: String
	public let courseCode: String?

	public init(id: String, courseID: String, accountID: String, name: String, courseCode: String?) {
		self.id = id
		self.courseID = courseID
		self.accountID = accountID
		self.name = name
		self.courseCode = courseCode
	}

	public init(accountID: String, courseID: String, name: String, courseCode: String?) {
		self.init(
			id: "\(accountID):\(courseID)",
			courseID: courseID,
			accountID: accountID,
			name: name,
			courseCode: courseCode
		)
	}
}

/// An assignment that a scheduled reminder can be derived from.
public struct CanvasAssignment: Sendable, Identifiable, Equatable, Codable {
	public let id: String
	public let course: CanvasCourse
	public let name: String
	/// The assignment's due date, in absolute terms.
	public let dueAt: Date?
	/// The start of the assignment's availability window, if the course sets one.
	public let unlockAt: Date?
	/// The end of the assignment's availability window, if the course sets one.
	public let lockAt: Date?
	public let isPublished: Bool
	/// Whether the signed-in user has already handed this one in.
	public let isSubmitted: Bool
	public let htmlURL: URL?

	public init(
		id: String,
		course: CanvasCourse,
		name: String,
		dueAt: Date?,
		unlockAt: Date?,
		lockAt: Date?,
		isPublished: Bool,
		isSubmitted: Bool,
		htmlURL: URL?
	) {
		self.id = id
		self.course = course
		self.name = name
		self.dueAt = dueAt
		self.unlockAt = unlockAt
		self.lockAt = lockAt
		self.isPublished = isPublished
		self.isSubmitted = isSubmitted
		self.htmlURL = htmlURL
	}

	/// Whether this assignment may produce reminders at all.
	///
	/// A submitted assignment needs no shouting about, an unpublished one is not the
	/// student's business yet, and without a due date there is nothing to be relative to.
	public var canProduceReminders: Bool {
		isPublished && !isSubmitted && dueAt != nil
	}
}

/// A time of day, without a date or a time zone.
///
/// Rules that fire "at 09:00" resolve it against the user's own calendar and time zone,
/// which is where the assignment's due day is judged from too.
public struct TimeOfDay: Sendable, Equatable, Hashable, Codable {
	public let hour: Int
	public let minute: Int

	public init(hour: Int, minute: Int) {
		self.hour = hour
		self.minute = minute
	}

	public static let defaultMorning = TimeOfDay(hour: 9, minute: 0)

	/// Clamps the values into a valid time of day.
	public var clamped: TimeOfDay {
		TimeOfDay(hour: min(max(hour, 0), 23), minute: min(max(minute, 0), 59))
	}
}

extension TimeOfDay: Comparable {
	public static func < (lhs: TimeOfDay, rhs: TimeOfDay) -> Bool {
		(lhs.hour, lhs.minute) < (rhs.hour, rhs.minute)
	}
}

/// One of the ways the user can ask to be reminded about an assignment relative to its due date.
public struct CanvasReminderRule: Sendable, Identifiable, Equatable, Codable {
	public enum Kind: String, Sendable, CaseIterable, Codable {
		/// A fixed number of days before the due date, at a fixed time of day.
		case daysBefore
		/// On the due date itself, at a fixed time of day.
		case onDueDay
		/// A fixed span before the assignment's own due time.
		case beforeDue

		/// The order the kinds are listed in. Not the raw value's order, which is alphabetical.
		var sortOrder: Int {
			switch self {
			case .daysBefore: 0
			case .onDueDay: 1
			case .beforeDue: 2
			}
		}
	}

	public var id: UUID
	public var kind: Kind
	/// Used by `.daysBefore`.
	public var days: Int
	/// Used by `.daysBefore` and `.onDueDay`.
	public var time: TimeOfDay
	/// Used by `.beforeDue`.
	public var minutes: Int

	public init(
		id: UUID = UUID(),
		kind: Kind,
		days: Int = 1,
		time: TimeOfDay = .defaultMorning,
		minutes: Int = 60
	) {
		self.id = id
		self.kind = kind
		self.days = days
		self.time = time
		self.minutes = minutes
	}

	/// The spans offered by the `.beforeDue` picker.
	///
	/// Every one is a whole number of minutes, hours or days, so a span never has to be
	/// described with two units at once.
	public static let offsetChoices = [
		15, 30, 45, 60, 120, 180, 240, 360, 480, 720, 1440, 2880, 10080,
	]

	/// Keeps the parameters in range regardless of what the fields were handed.
	public var normalized: CanvasReminderRule {
		var copy = self
		copy.days = max(0, days)
		copy.minutes = max(1, minutes)
		copy.time = time.clamped
		return copy
	}
}

extension CanvasReminderRule: Comparable {
	/// Orders rules the way the table lists them: the three kinds in a fixed order, and within a
	/// kind the reminder that comes first in time.
	public static func < (lhs: CanvasReminderRule, rhs: CanvasReminderRule) -> Bool {
		let lhs = lhs.normalized
		let rhs = rhs.normalized
		guard lhs.kind == rhs.kind else { return lhs.kind.sortOrder < rhs.kind.sortOrder }

		switch lhs.kind {
		case .daysBefore:
			return lhs.days == rhs.days ? lhs.time < rhs.time : lhs.days > rhs.days
		case .onDueDay:
			return lhs.time < rhs.time
		case .beforeDue:
			return lhs.minutes > rhs.minutes
		}
	}
}

/// Canvas exposes no colour for a course, so every course reminder uses one accent.
public enum CanvasPalette {
	public static let courseColor = RGBColor(red: 0.29, green: 0.46, blue: 0.7)
}
