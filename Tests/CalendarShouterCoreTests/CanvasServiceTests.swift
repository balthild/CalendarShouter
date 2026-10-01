import Foundation
import Testing

@testable import CalendarShouterCore

/// A fixed calendar so the fire times below are plain arithmetic.
private let utcCalendar: Calendar = {
	var calendar = Calendar(identifier: .gregorian)
	calendar.timeZone = TimeZone(identifier: "UTC")!
	return calendar
}()

private func date(
	_ year: Int,
	_ month: Int,
	_ day: Int,
	_ hour: Int = 0,
	_ minute: Int = 0
)
	-> Date
{
	utcCalendar.date(
		from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute)
	)!
}

private func makeDefaults() -> UserDefaults {
	let suiteName = "CalendarShouterTests.\(UUID().uuidString)"
	let defaults = UserDefaults(suiteName: suiteName)!
	defaults.removePersistentDomain(forName: suiteName)
	return defaults
}

/// Secrets kept in memory, so no test touches the real keychain.
final class InMemorySecretStore: SecretStore, @unchecked Sendable {
	private var storage: [String: Data] = [:]

	func data(for key: String) throws -> Data? { storage[key] }

	func set(_ data: Data, for key: String) throws { storage[key] = data }

	func removeValue(for key: String) throws { storage[key] = nil }

	func contains(_ key: String) -> Bool { storage[key] != nil }
}

final class FakeCanvasAPI: CanvasAPIClient, @unchecked Sendable {
	nonisolated(unsafe) var verification = CanvasDomainVerification(
		result: .success,
		baseURL: URL(string: "https://canvas.example.edu")!,
		credentials: CanvasClientCredentials(clientID: "1", clientSecret: "s")
	)
	nonisolated(unsafe) var authenticatedUser = CanvasAuthenticatedUser(id: "7", name: "Student")
	nonisolated(unsafe) var courseRecords: [CanvasCourseRecord] = []
	nonisolated(unsafe) var assignmentRecords: [CanvasAssignmentRecord] = []
	/// Tokens Canvas rejects, so the refresh-and-retry path can be driven.
	nonisolated(unsafe) var unauthorizedTokens: Set<String> = []
	nonisolated(unsafe) var refreshedTokens = CanvasTokens(
		accessToken: "new",
		refreshToken: "rt",
		expiresAt: .distantFuture
	)
	nonisolated(unsafe) private(set) var refreshCalls = 0
	nonisolated(unsafe) private(set) var coursesCallCount = 0

	func verifyDomain(_ domain: String) async throws -> CanvasDomainVerification { verification }

	func authenticate(
		code: String,
		credentials: CanvasClientCredentials,
		baseURL: URL
	) async throws -> (tokens: CanvasTokens, user: CanvasAuthenticatedUser) {
		(
			tokens: CanvasTokens(accessToken: "at", refreshToken: "rt", expiresAt: .distantFuture),
			user: authenticatedUser
		)
	}

	func refresh(
		credentials: CanvasClientCredentials,
		refreshToken: String,
		baseURL: URL
	) async throws -> CanvasTokens {
		refreshCalls += 1
		return refreshedTokens
	}

	func courses(accessToken: String, baseURL: URL) async throws -> [CanvasCourseRecord] {
		coursesCallCount += 1
		if unauthorizedTokens.contains(accessToken) {
			throw CanvasAPIError.http(status: 401, message: nil)
		}
		return courseRecords
	}

	func assignments(
		courseID: String,
		accessToken: String,
		baseURL: URL
	) async throws -> [CanvasAssignmentRecord] {
		if unauthorizedTokens.contains(accessToken) {
			throw CanvasAPIError.http(status: 401, message: nil)
		}
		return assignmentRecords
	}
}

@MainActor
private func makeService(
	api: FakeCanvasAPI,
	settings: SettingsStore,
	secrets: InMemorySecretStore
) -> CanvasService {
	CanvasService(api: api, settings: settings, secrets: secrets, calendar: utcCalendar)
}

private func makeRecord(
	id: String = "4",
	dueAt: Date? = date(2026, 3, 10, 23, 59),
	isSubmitted: Bool = false
) -> CanvasAssignmentRecord {
	CanvasAssignmentRecord(
		id: id,
		name: "Problem set",
		dueAt: dueAt,
		unlockAt: nil,
		lockAt: nil,
		isPublished: true,
		isSubmitted: isSubmitted,
		htmlURL: nil
	)
}

/// Registers an account along with the tokens and credentials a refresh needs.
@MainActor
@discardableResult
private func addAccount(
	id: String = "acc-1",
	domain: String = "canvas.example.edu",
	addedAt: Date = date(2026, 1, 1),
	accessToken: String = "at",
	to settings: SettingsStore,
	secrets: InMemorySecretStore
) throws -> CanvasAccount {
	let account = CanvasAccount(
		id: id,
		domain: domain,
		baseURL: URL(string: "https://\(domain)")!,
		userID: "7",
		userName: "Student",
		addedAt: addedAt
	)
	settings.canvasAccounts.append(account)
	try secrets.setValue(
		CanvasTokens(accessToken: accessToken, refreshToken: "rt", expiresAt: .distantFuture),
		for: KeychainStore.Item.tokens(accountID: id)
	)
	try secrets.setValue(
		CanvasClientCredentials(clientID: "1", clientSecret: "s"),
		for: KeychainStore.Item.client(accountID: id)
	)
	return account
}

@Suite("Canvas service")
@MainActor
struct CanvasServiceTests {
	@Test("A domain Canvas rejects is reported without a sign-in attempt")
	func verifyRejectedDomain() async throws {
		let api = FakeCanvasAPI()
		api.verification = CanvasDomainVerification(
			result: .domainNotAuthorized,
			baseURL: nil,
			credentials: nil
		)
		let service = makeService(
			api: api,
			settings: SettingsStore(defaults: makeDefaults()),
			secrets: InMemorySecretStore()
		)

		await #expect(throws: CanvasService.SignInError.domainNotAuthorized) {
			_ = try await service.verifyDomain("example.com")
		}
	}

	@Test("A domain that is not a host at all never reaches the network")
	func verifyUnparsableDomain() async throws {
		let api = FakeCanvasAPI()
		let service = makeService(
			api: api,
			settings: SettingsStore(defaults: makeDefaults()),
			secrets: InMemorySecretStore()
		)

		await #expect(throws: CanvasService.SignInError.unknownDomain) {
			_ = try await service.verifyDomain("localhost")
		}
	}

	@Test("Signing in records the account and keeps its secrets out of preferences")
	func signIn() async throws {
		let defaults = makeDefaults()
		let settings = SettingsStore(defaults: defaults)
		let secrets = InMemorySecretStore()
		let api = FakeCanvasAPI()
		let service = makeService(api: api, settings: settings, secrets: secrets)

		let pending = try await service.verifyDomain("canvas.example.edu")
		let account = try await service.signIn(pending, code: "abc")

		#expect(account.id == "canvas.example.edu#7")
		#expect(account.domain == "canvas.example.edu")
		#expect(account.userName == "Student")
		#expect(settings.canvasAccounts.map(\.id) == [account.id])
		#expect(secrets.contains(KeychainStore.Item.tokens(accountID: account.id)))
		#expect(secrets.contains(KeychainStore.Item.client(accountID: account.id)))

		// The account itself must carry no secrets into the preferences file.
		let stored = String(decoding: defaults.data(forKey: "canvasAccounts") ?? Data(), as: UTF8.self)
		#expect(!stored.contains("secret"))
		#expect(!stored.contains("\"at\""))
	}

	@Test("Refreshing caches courses and assignments and announces the change")
	func refreshCaches() async throws {
		let settings = SettingsStore(defaults: makeDefaults())
		let api = FakeCanvasAPI()
		api.courseRecords = [
			CanvasCourseRecord(id: "1", name: "Algorithms", courseCode: "CS301")
		]
		api.assignmentRecords = [makeRecord()]

		var changes = 0
		let secrets = InMemorySecretStore()
		let service = makeService(api: api, settings: settings, secrets: secrets)
		service.onChange = { changes += 1 }

		try addAccount(to: settings, secrets: secrets)

		service.refresh()
		await service.currentRefresh?.value

		#expect(service.courses(forAccountID: "acc-1").map(\.name) == ["Algorithms"])
		#expect(changes == 1)
	}

	@Test("A rejected access token is refreshed and the request retried once")
	func refreshesExpiredToken() async throws {
		let settings = SettingsStore(defaults: makeDefaults())
		let secrets = InMemorySecretStore()
		let api = FakeCanvasAPI()
		api.unauthorizedTokens = ["old"]
		api.courseRecords = [CanvasCourseRecord(id: "1", name: "Algorithms", courseCode: nil)]

		let accountID = "acc-1"
		try secrets.setValue(
			CanvasTokens(accessToken: "old", refreshToken: "rt", expiresAt: .distantFuture),
			for: KeychainStore.Item.tokens(accountID: accountID)
		)
		try secrets.setValue(
			CanvasClientCredentials(clientID: "1", clientSecret: "s"),
			for: KeychainStore.Item.client(accountID: accountID)
		)
		settings.canvasAccounts = [
			CanvasAccount(
				id: accountID,
				domain: "canvas.example.edu",
				baseURL: URL(string: "https://canvas.example.edu")!,
				userID: "7",
				userName: "Student",
				addedAt: .distantPast
			)
		]

		let service = makeService(api: api, settings: settings, secrets: secrets)
		service.refresh()
		await service.currentRefresh?.value

		#expect(api.refreshCalls == 1)
		#expect(service.courses(forAccountID: accountID).count == 1)
		#expect(service.needsReauthentication.isEmpty)
	}

	@Test("An account Canvas keeps refusing is flagged for signing in again")
	func marksAccountForReauthentication() async throws {
		let settings = SettingsStore(defaults: makeDefaults())
		let secrets = InMemorySecretStore()
		let api = FakeCanvasAPI()
		api.unauthorizedTokens = ["old", "new"]

		let accountID = "acc-1"
		try secrets.setValue(
			CanvasTokens(accessToken: "old", refreshToken: "rt", expiresAt: .distantFuture),
			for: KeychainStore.Item.tokens(accountID: accountID)
		)
		try secrets.setValue(
			CanvasClientCredentials(clientID: "1", clientSecret: "s"),
			for: KeychainStore.Item.client(accountID: accountID)
		)
		settings.canvasAccounts = [
			CanvasAccount(
				id: accountID,
				domain: "canvas.example.edu",
				baseURL: URL(string: "https://canvas.example.edu")!,
				userID: "7",
				userName: "Student",
				addedAt: .distantPast
			)
		]

		let service = makeService(api: api, settings: settings, secrets: secrets)
		service.refresh()
		await service.currentRefresh?.value

		#expect(service.needsReauthentication == [accountID])
	}

	@Test("Reminders are derived from the assignments and the user's rules")
	func remindersFromRules() async throws {
		let settings = SettingsStore(defaults: makeDefaults())
		settings.canvasReminderRules = [
			CanvasReminderRule(kind: .beforeDue, minutes: 60)
		]
		let api = FakeCanvasAPI()
		api.courseRecords = [CanvasCourseRecord(id: "1", name: "Algorithms", courseCode: nil)]
		api.assignmentRecords = [makeRecord()]

		let secrets = InMemorySecretStore()
		let service = makeService(api: api, settings: settings, secrets: secrets)
		try addAccount(to: settings, secrets: secrets)

		service.refresh()
		await service.currentRefresh?.value

		let reminders = service.reminders(from: date(2026, 3, 1), to: date(2026, 4, 1))
		#expect(reminders.count == 1)
		#expect(reminders.first?.fireDates == [date(2026, 3, 10, 22, 59)])
		#expect(reminders.first?.calendar.title == "Algorithms")

		// Outside the window there is nothing to say.
		#expect(service.reminders(from: date(2026, 4, 1), to: date(2026, 5, 1)).isEmpty)
	}

	@Test("A submitted assignment is never announced")
	func submittedAssignmentIsSilent() async throws {
		let settings = SettingsStore(defaults: makeDefaults())
		settings.canvasReminderRules = [CanvasReminderRule(kind: .beforeDue, minutes: 60)]
		let api = FakeCanvasAPI()
		api.courseRecords = [CanvasCourseRecord(id: "1", name: "Algorithms", courseCode: nil)]
		api.assignmentRecords = [makeRecord(isSubmitted: true)]

		let secrets = InMemorySecretStore()
		let service = makeService(api: api, settings: settings, secrets: secrets)
		try addAccount(to: settings, secrets: secrets)

		service.refresh()
		await service.currentRefresh?.value

		#expect(service.reminders(from: date(2026, 3, 1), to: date(2026, 4, 1)).isEmpty)
	}

	@Test("Removing an account forgets its secrets, courses and course selection")
	func removeAccount() async throws {
		let settings = SettingsStore(defaults: makeDefaults())
		settings.canvasReminderRules = [CanvasReminderRule(kind: .beforeDue, minutes: 60)]
		let secrets = InMemorySecretStore()
		let api = FakeCanvasAPI()
		api.courseRecords = [CanvasCourseRecord(id: "1", name: "Algorithms", courseCode: nil)]
		api.assignmentRecords = [makeRecord()]

		let account = try addAccount(to: settings, secrets: secrets)

		let service = makeService(api: api, settings: settings, secrets: secrets)
		service.refresh()
		await service.currentRefresh?.value
		settings.setCanvasReminderEnabled(true, forCourseID: "acc-1:1")

		service.removeAccount(account)

		#expect(settings.canvasAccounts.isEmpty)
		#expect(service.courses.isEmpty)
		#expect(settings.enabledCanvasCourseIDs.isEmpty)
		#expect(!secrets.contains(KeychainStore.Item.tokens(accountID: account.id)))
		#expect(service.reminders(from: date(2026, 3, 1), to: date(2026, 4, 1)).isEmpty)
	}
}

/// Canvas as the scheduler sees it: a bag of prepared reminder events.
@MainActor
final class FakeCanvasService: CanvasServicing {
	var eventsToReturn: [ReminderEvent] = []
	private(set) var refreshCount = 0

	func reminders(from startDate: Date, to endDate: Date) -> [ReminderEvent] {
		eventsToReturn.filter { event in
			event.fireDates.contains { $0 > startDate && $0 <= endDate }
		}
	}

	func refresh() { refreshCount += 1 }
}

@Suite("Canvas scheduling")
@MainActor
struct CanvasSchedulingTests {
	private func makeSettings(_ defaults: UserDefaults, enabling courses: [String]) -> SettingsStore {
		let settings = SettingsStore(defaults: defaults)
		for course in courses {
			settings.setCanvasReminderEnabled(true, forCourseID: course)
		}
		return settings
	}

	private func makeEvent(courseID: String, fireDate: Date) -> ReminderEvent {
		ReminderEvent(
			id: "canvas:4",
			title: "Problem set",
			startDate: fireDate,
			endDate: fireDate,
			isAllDay: false,
			location: nil,
			notes: nil,
			calendar: CalendarInfo(
				id: courseID,
				title: "Algorithms",
				color: CanvasPalette.courseColor,
				account: CalendarAccountRef(id: "acc-1", title: "Student", kind: .other)
			),
			fireDates: [fireDate]
		)
	}

	private func makeScheduler(
		settings: SettingsStore,
		canvas: FakeCanvasService,
		clock: FakeClock,
		defaults: UserDefaults
	) -> ReminderScheduler {
		ReminderScheduler(
			service: FakeCalendarService(),
			settings: settings,
			canvas: canvas,
			clock: clock,
			defaults: defaults
		)
	}

	@Test("A Canvas course that is switched off stays silent")
	func disabledCourseIsSilent() {
		let defaults = makeDefaults()
		let clock = FakeClock(now: date(2026, 3, 1))
		let canvas = FakeCanvasService()
		canvas.eventsToReturn = [makeEvent(courseID: "acc-1:1", fireDate: date(2026, 3, 1, 12))]

		let settings = makeSettings(defaults, enabling: [])
		let scheduler = makeScheduler(
			settings: settings,
			canvas: canvas,
			clock: clock,
			defaults: defaults
		)
		scheduler.reload()

		#expect(scheduler.upcomingFires.isEmpty)
	}

	@Test("A Canvas course that is switched on produces its reminders")
	func enabledCourseFires() {
		let defaults = makeDefaults()
		let clock = FakeClock(now: date(2026, 3, 1))
		let canvas = FakeCanvasService()
		canvas.eventsToReturn = [makeEvent(courseID: "acc-1:1", fireDate: date(2026, 3, 1, 12))]

		let settings = makeSettings(defaults, enabling: ["acc-1:1"])
		let scheduler = makeScheduler(
			settings: settings,
			canvas: canvas,
			clock: clock,
			defaults: defaults
		)
		scheduler.reload()

		#expect(scheduler.upcomingFires.count == 1)
		#expect(scheduler.upcomingFires.first?.event.calendar.id == "acc-1:1")
		#expect(clock.nextScheduledDate == date(2026, 3, 1, 12))
	}
}
