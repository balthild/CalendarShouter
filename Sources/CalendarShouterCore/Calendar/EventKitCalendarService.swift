import AppKit
@preconcurrency import EventKit
import Foundation
import Observation

/// Reads events and their alarms, and reminders, from the system store.
@MainActor
@Observable
public final class EventKitCalendarService: CalendarServicing {
	private let store: EKEventStore
	/// `nonisolated` so the deinitializer can reach it. `@ObservationIgnored` keeps it a stored
	/// property: as observable state the macro's computed accessor only warns about `(unsafe)`.
	@ObservationIgnored nonisolated(unsafe) private var storeChangeObserver: NSObjectProtocol?

	public private(set) var authorization: CalendarAuthorization = .notDetermined
	public private(set) var remindersAuthorization: CalendarAuthorization = .notDetermined
	public private(set) var accounts: [CalendarAccount] = []

	/// The most recent fetch of the user's reminders.
	///
	/// `fetchReminders` reports its results through a callback, whereas the scheduler reads
	/// the store synchronously, so the fetched reminders are cached here and changes are
	/// signalled through `onChange`.
	@ObservationIgnored private var cachedReminders: [ReminderEvent] = []
	/// The in-flight reminder fetch, so a newer one can cancel it. `Any` is the cancellation
	/// token `fetchReminders` returns.
	@ObservationIgnored private var reminderFetchRequest: Any?
	/// Bumped by every reminder refresh, so a superseded fetch that still calls back cannot
	/// overwrite the results of the one that replaced it.
	@ObservationIgnored private var reminderFetchGeneration = 0

	/// Invoked whenever the calendar store changes, so the scheduler can reload.
	public var onChange: (() -> Void)?

	public init(store: EKEventStore = EKEventStore()) {
		self.store = store
		refresh()
		reloadReminders()
		storeChangeObserver = NotificationCenter.default.addObserver(
			forName: .EKEventStoreChanged,
			object: store,
			queue: .main
		) { [weak self] _ in
			// The observer is registered on the main queue.
			MainActor.assumeIsolated {
				self?.refresh()
				self?.reloadReminders()
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

	public func requestRemindersAccess() async -> Bool {
		do {
			let granted = try await store.requestFullAccessToReminders()
			reloadReminders()
			return granted
		} catch {
			reloadReminders()
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

	/// Re-reads the user's reminders and caches them.
	///
	/// The fetch is asynchronous; when it lands the cache is replaced and `onChange` is
	/// signalled, which is what makes the scheduler pick the reminders up.
	public func reloadReminders() {
		remindersAuthorization = Self.authorization(
			from: EKEventStore.authorizationStatus(for: .reminder)
		)
		reminderFetchGeneration += 1
		let generation = reminderFetchGeneration

		if let reminderFetchRequest {
			store.cancelFetchRequest(reminderFetchRequest)
			self.reminderFetchRequest = nil
		}

		guard remindersAuthorization.canReadReminders else {
			guard !cachedReminders.isEmpty else { return }
			cachedReminders = []
			onChange?()
			return
		}

		// Reminders are fetched in full rather than by due-date window: a reminder may be
		// set to shout from an alarm alone, with no due date to window on.
		//
		// `@Sendable` is load-bearing: a plain closure formed inside this main-actor class
		// is itself main-actor isolated, and EventKit answers on its own queue, so the
		// isolation check would trap the moment the fetch came back.
		reminderFetchRequest = store.fetchReminders(
			matching: store.predicateForReminders(in: nil)
		) { @Sendable [weak self] reminders in
			// The callback is not tied to any queue, so the mapping runs where it lands and
			// only the resulting value crosses back to the main actor.
			let fetched = (reminders ?? []).compactMap { Self.reminderEvent(from: $0) }
			Task { @MainActor [weak self] in
				guard let self, self.reminderFetchGeneration == generation else { return }
				self.reminderFetchRequest = nil
				self.cachedReminders = fetched
				self.onChange?()
			}
		}
	}

	public func events(from startDate: Date, to endDate: Date) -> [ReminderEvent] {
		guard authorization.canReadEvents else { return [] }
		let predicate = store.predicateForEvents(withStart: startDate, end: endDate, calendars: nil)
		return store.events(matching: predicate).compactMap { event in
			Self.reminderEvent(from: event)
		}
	}

	public func reminders(from startDate: Date, to endDate: Date) -> [ReminderEvent] {
		guard remindersAuthorization.canReadReminders else { return [] }
		return cachedReminders.filter { reminder in
			reminder.fireDates.contains { $0 > startDate && $0 <= endDate }
		}
	}
}

// MARK: - EventKit conversion

/// The conversions are deliberately `nonisolated`: they are pure, and the reminder fetch
/// resolves its results on whatever queue EventKit calls back on.
@MainActor
extension EventKitCalendarService {
	nonisolated static func authorization(from status: EKAuthorizationStatus) -> CalendarAuthorization
	{
		switch status {
		case .notDetermined: .notDetermined
		case .restricted: .restricted
		case .denied: .denied
		case .writeOnly: .writeOnly
		case .fullAccess: .fullAccess
		@unknown default: .notDetermined
		}
	}

	nonisolated static func rgbColor(from cgColor: CGColor?) -> RGBColor {
		// Used when a calendar has no colour of its own.
		let fallback = RGBColor(red: 0.56, green: 0.56, blue: 0.58)
		guard let cgColor, let color = NSColor(cgColor: cgColor)?.usingColorSpace(.sRGB) else {
			return fallback
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
	nonisolated static func accountRef(from source: EKSource?) -> CalendarAccountRef {
		guard let source else {
			return CalendarAccountRef(id: "", title: "", kind: .other)
		}
		return CalendarAccountRef(
			id: source.sourceIdentifier,
			title: source.title,
			kind: kind(from: source.sourceType)
		)
	}

	nonisolated static func kind(from sourceType: EKSourceType) -> CalendarAccountKind {
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

	nonisolated static func calendarInfo(from calendar: EKCalendar) -> CalendarInfo {
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
	nonisolated static func reminderEvent(from event: EKEvent) -> ReminderEvent? {
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

	/// A reminder's due date, resolved into the instants a reminder is shown at.
	struct ReminderDue {
		let startDate: Date
		let endDate: Date
		let fireDate: Date
		let isAllDay: Bool
	}

	/// Converts a reminder, returning `nil` when it should never produce a reminder.
	///
	/// Completed reminders are skipped, as are reminders that offer neither a time-based
	/// alarm nor a due date: there would be no instant to shout at.
	nonisolated static func reminderEvent(from reminder: EKReminder) -> ReminderEvent? {
		guard !reminder.isCompleted else { return nil }
		guard let calendar = reminder.calendar else { return nil }

		let due = due(from: reminder.dueDateComponents)

		let alarmDates = (reminder.alarms ?? []).filter { $0.isTimeBased }.compactMap {
			alarm -> Date? in
			// An absolute alarm fires at its own instant; a relative one is an offset
			// from the reminder's due date.
			alarm.absoluteDate ?? due?.fireDate.addingTimeInterval(alarm.relativeOffset)
		}
		let fireDates = alarmDates.isEmpty ? due.map { [$0.fireDate] } ?? [] : alarmDates
		guard !fireDates.isEmpty else { return nil }

		return ReminderEvent(
			id: reminder.calendarItemIdentifier,
			title: (reminder.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
			startDate: due?.startDate ?? fireDates.min() ?? Date(),
			endDate: due?.endDate ?? fireDates.max() ?? Date(),
			isAllDay: due?.isAllDay ?? false,
			location: nil,
			notes: reminder.notes?.trimmedOrNil,
			calendar: calendarInfo(from: calendar),
			fireDates: fireDates
		)
	}

	/// Resolves a reminder's due date components.
	///
	/// A due date that names a time of day is a single instant. A date-only due date has no
	/// time at all, so it is announced mid-morning and shown as an all-day item, rather than
	/// at midnight, when the day it belongs to has not really started.
	nonisolated static func due(from components: DateComponents?) -> ReminderDue? {
		guard let components, let date = Calendar.current.date(from: components) else { return nil }

		guard components.hour != nil else {
			let hour = 9
			let startDate = Calendar.current.startOfDay(for: date)
			let fireDate = Calendar.current.date(byAdding: .hour, value: hour, to: startDate) ?? startDate
			let endDate = Calendar.current.date(byAdding: .day, value: 1, to: startDate) ?? startDate
			return ReminderDue(
				startDate: startDate,
				endDate: endDate,
				fireDate: fireDate,
				isAllDay: true
			)
		}
		return ReminderDue(startDate: date, endDate: date, fireDate: date, isAllDay: false)
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
