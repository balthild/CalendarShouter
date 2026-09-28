import AppKit
@preconcurrency import EventKit
import Foundation
import Observation

/// Reads events and their alarms from the system calendar store.
@MainActor
@Observable
public final class EventKitCalendarService: CalendarServicing {
	/// Used when a calendar has no colour of its own.
	private static let defaultColor = RGBColor(red: 0.56, green: 0.56, blue: 0.58)

	private let store: EKEventStore
	/// `nonisolated` so the deinitializer can reach it. `@ObservationIgnored` keeps it a stored
	/// property: as observable state the macro's computed accessor only warns about `(unsafe)`.
	@ObservationIgnored nonisolated(unsafe) private var storeChangeObserver: NSObjectProtocol?

	public private(set) var authorization: CalendarAuthorization = .notDetermined
	public private(set) var accounts: [CalendarAccount] = []

	/// Invoked whenever the calendar store changes, so the scheduler can reload.
	public var onChange: (() -> Void)?

	public init(store: EKEventStore = EKEventStore()) {
		self.store = store
		refresh()
		storeChangeObserver = NotificationCenter.default.addObserver(
			forName: .EKEventStoreChanged,
			object: store,
			queue: .main
		) { [weak self] _ in
			// The observer is registered on the main queue.
			MainActor.assumeIsolated {
				self?.refresh()
				self?.onChange?()
			}
		}
	}

	deinit {
		if let storeChangeObserver {
			NotificationCenter.default.removeObserver(storeChangeObserver)
		}
	}

	public func requestAccess() async -> Bool {
		do {
			let granted = try await store.requestFullAccessToEvents()
			refresh()
			return granted
		} catch {
			refresh()
			return false
		}
	}

	public func refresh() {
		authorization = Self.authorization(from: EKEventStore.authorizationStatus(for: .event))
		guard authorization.canReadEvents else {
			accounts = []
			return
		}
		accounts = CalendarAccount.grouped(
			store.calendars(for: .event).map { Self.calendarInfo(from: $0) }
		)
	}

	public func events(from startDate: Date, to endDate: Date) -> [ReminderEvent] {
		guard authorization.canReadEvents else { return [] }
		let predicate = store.predicateForEvents(withStart: startDate, end: endDate, calendars: nil)
		return store.events(matching: predicate).compactMap { event in
			Self.reminderEvent(from: event)
		}
	}
}

// MARK: - EventKit conversion

@MainActor
extension EventKitCalendarService {
	static func authorization(from status: EKAuthorizationStatus) -> CalendarAuthorization {
		switch status {
		case .notDetermined: .notDetermined
		case .restricted: .restricted
		case .denied: .denied
		case .writeOnly: .writeOnly
		case .fullAccess: .fullAccess
		@unknown default: .notDetermined
		}
	}

	static func rgbColor(from cgColor: CGColor?) -> RGBColor {
		guard let cgColor, let color = NSColor(cgColor: cgColor)?.usingColorSpace(.sRGB) else {
			return defaultColor
		}
		return RGBColor(
			red: Double(color.redComponent),
			green: Double(color.greenComponent),
			blue: Double(color.blueComponent),
			alpha: Double(color.alphaComponent)
		)
	}

	/// The account a calendar belongs to.
	///
	/// A calendar always belongs to a source in practice, but the property is
	/// optional; a calendar without one is reported as its own unnamed account
	/// rather than dropped.
	static func accountRef(from source: EKSource?) -> CalendarAccountRef {
		guard let source else {
			return CalendarAccountRef(id: "", title: "", kind: .other)
		}
		return CalendarAccountRef(
			id: source.sourceIdentifier,
			title: source.title,
			kind: kind(from: source.sourceType)
		)
	}

	static func kind(from sourceType: EKSourceType) -> CalendarAccountKind {
		switch sourceType {
		case .local: .local
		case .exchange: .exchange
		case .calDAV: .calDAV
		case .mobileMe: .mobileMe
		case .subscribed: .subscribed
		case .birthdays: .birthdays
		@unknown default: .other
		}
	}

	static func calendarInfo(from calendar: EKCalendar) -> CalendarInfo {
		CalendarInfo(
			id: calendar.calendarIdentifier,
			title: calendar.title,
			color: rgbColor(from: calendar.cgColor),
			account: accountRef(from: calendar.source)
		)
	}

	/// Converts an event, returning `nil` when it should never produce a reminder.
	///
	/// Events are skipped when they are cancelled, declined by the user, or carry
	/// no alarm that fires at a point in time (location-based alarms are ignored).
	static func reminderEvent(from event: EKEvent) -> ReminderEvent? {
		guard let startDate = event.startDate, let endDate = event.endDate else { return nil }
		guard event.status != .canceled else { return nil }
		guard let calendar = event.calendar else { return nil }

		if let attendees = event.attendees,
			attendees.contains(where: { $0.isCurrentUser && $0.participantStatus == .declined })
		{
			return nil
		}

		let timeBasedAlarms = (event.alarms ?? []).filter { $0.isTimeBased }
		let fireDates = timeBasedAlarms.map { alarm in
			// An absolute alarm fires at its own instant; a relative one is an
			// offset from the start of the event.
			alarm.absoluteDate ?? startDate.addingTimeInterval(alarm.relativeOffset)
		}
		guard !fireDates.isEmpty else { return nil }

		return ReminderEvent(
			id: event.eventIdentifier ?? UUID().uuidString,
			title: (event.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
			startDate: startDate,
			endDate: endDate,
			isAllDay: event.isAllDay,
			location: event.location?.trimmedOrNil,
			notes: event.notes?.trimmedOrNil,
			calendar: calendarInfo(from: calendar),
			fireDates: fireDates
		)
	}
}

extension EKAlarm {
	/// Whether this alarm fires at a point in time, as opposed to on entering or
	/// leaving a location.
	var isTimeBased: Bool { proximity == .none }
}

extension String {
	var trimmedOrNil: String? {
		let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
		return trimmed.isEmpty ? nil : trimmed
	}
}
