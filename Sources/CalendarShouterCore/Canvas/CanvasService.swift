import Foundation
import Observation

/// Read access to Canvas reminders, as the scheduler needs it.
///
/// Synchronous and cache-backed for the same reason `CalendarServicing` is: the scheduler
/// evaluates on a timer and its tests drive a fake clock, so nothing on that path may wait
/// on a network. The cache is filled in the background and announces itself through `onChange`.
@MainActor
public protocol CanvasServicing: AnyObject {
	/// The reminders with a fire time inside the window, read from the cache.
	func reminders(from startDate: Date, to endDate: Date) -> [ReminderEvent]
	/// Re-reads Canvas in the background.
	func refresh()
}

/// Signs in to Canvas accounts and keeps a cache of their courses and assignments.
@MainActor
@Observable
public final class CanvasService: CanvasServicing {
	/// A domain that has been verified and is waiting for the user to authorize it.
	public struct PendingSignIn: Sendable {
		public let domain: String
		public let baseURL: URL
		public let credentials: CanvasClientCredentials
	}

	public enum SignInError: Error, Equatable {
		case unknownDomain
		/// Canvas does not recognise the domain, or its mobile access is switched off.
		case domainNotAuthorized
		/// The verification endpoint did not accept the app as a client.
		case unsupportedClient
		case cancelled
		case notSignedIn
		case failed(String)
	}

	public private(set) var courses: [CanvasCourse] = []
	public private(set) var isRefreshing = false
	/// Accounts whose credentials no longer work, so the pane can offer to sign in again.
	public private(set) var needsReauthentication: Set<String> = []

	var onChange: (() -> Void)?

	private let api: CanvasAPIClient
	private let secrets: any SecretStore
	private let settings: SettingsStore
	private let calendar: Calendar

	private var assignments: [CanvasAssignment] = []
	private var refreshTask: Task<Void, Never>?
	/// Guards against a slow refresh overwriting a newer one's results.
	private var generation = 0

	public init(
		api: CanvasAPIClient,
		settings: SettingsStore,
		secrets: any SecretStore = KeychainStore(),
		calendar: Calendar = .current
	) {
		self.api = api
		self.settings = settings
		self.secrets = secrets
		self.calendar = calendar
	}

	public func courses(forAccountID identifier: String) -> [CanvasCourse] {
		courses.filter { $0.accountID == identifier }
	}

	// MARK: - Signing in

	/// Checks a domain and fetches the credentials Canvas has registered for it.
	public func verifyDomain(_ input: String) async throws -> PendingSignIn {
		guard let domain = CanvasOAuth.normalizedDomain(input) else {
			throw SignInError.unknownDomain
		}

		let verification = try await api.verifyDomain(domain)
		switch verification.result {
		case .success:
			guard let baseURL = verification.baseURL, let credentials = verification.credentials else {
				throw SignInError.domainNotAuthorized
			}
			return PendingSignIn(domain: domain, baseURL: baseURL, credentials: credentials)
		case .domainNotAuthorized, .unknown:
			throw SignInError.domainNotAuthorized
		case .unknownUserAgent:
			throw SignInError.unsupportedClient
		case .generalError:
			throw SignInError.failed("")
		}
	}

	/// Exchanges the authorization code for tokens and records the account.
	///
	/// The account id is derived from the domain and the user, so signing in twice does not
	/// leave two copies behind.
	public func signIn(_ pending: PendingSignIn, code: String) async throws -> CanvasAccount {
		let result = try await api.authenticate(
			code: code,
			credentials: pending.credentials,
			baseURL: pending.baseURL
		)

		let account = CanvasAccount(
			id: "\(pending.domain)#\(result.user.id)",
			domain: pending.domain,
			baseURL: pending.baseURL,
			userID: result.user.id,
			userName: result.user.name,
			addedAt: Date()
		)
		try secrets.setValue(pending.credentials, for: KeychainStore.Item.client(accountID: account.id))
		try secrets.setValue(result.tokens, for: KeychainStore.Item.tokens(accountID: account.id))

		settings.canvasAccounts.removeAll { $0.id == account.id }
		settings.canvasAccounts.append(account)
		needsReauthentication.remove(account.id)

		refresh()
		return account
	}

	public func removeAccount(_ account: CanvasAccount) {
		settings.canvasAccounts.removeAll { $0.id == account.id }
		try? secrets.removeValue(for: KeychainStore.Item.tokens(accountID: account.id))
		try? secrets.removeValue(for: KeychainStore.Item.client(accountID: account.id))

		courses.removeAll { $0.accountID == account.id }
		assignments.removeAll { $0.course.accountID == account.id }
		needsReauthentication.remove(account.id)
		settings.pruneCanvasCourseSelection(keeping: Set(courses.map(\.id)))
		onChange?()
	}

	// MARK: - Refreshing

	public func refresh() {
		refreshTask?.cancel()
		generation += 1
		let current = generation
		isRefreshing = true

		refreshTask = Task { [weak self] in
			await self?.performRefresh(generation: current)
		}
	}

	/// The refresh currently in flight.
	///
	/// Exposed so a caller that must not act on a stale cache can wait for the current
	/// fetch to land.
	var currentRefresh: Task<Void, Never>? { refreshTask }

	private func performRefresh(generation: Int) async {
		var fetchedCourses: [CanvasCourse] = []
		var fetchedAssignments: [CanvasAssignment] = []
		var needingSignIn: Set<String> = []

		for account in settings.canvasAccounts {
			do {
				let records = try await withValidToken(for: account) { token in
					try await self.api.courses(accessToken: token, baseURL: account.baseURL)
				}
				let accountCourses = records.map {
					CanvasCourse(
						accountID: account.id,
						courseID: $0.id,
						name: $0.name,
						courseCode: $0.courseCode
					)
				}
				fetchedCourses.append(contentsOf: accountCourses)

				for course in accountCourses {
					let assignmentRecords = try await withValidToken(for: account) { token in
						try await self.api.assignments(
							courseID: course.courseID,
							accessToken: token,
							baseURL: account.baseURL
						)
					}
					fetchedAssignments.append(
						contentsOf: assignmentRecords.map { record in
							CanvasAssignment(
								id: "\(course.id):\(record.id)",
								course: course,
								name: record.name,
								dueAt: record.dueAt,
								unlockAt: record.unlockAt,
								lockAt: record.lockAt,
								isPublished: record.isPublished,
								isSubmitted: record.isSubmitted,
								htmlURL: record.htmlURL
							)
						}
					)
				}
			} catch CanvasAPIError.http(let status, _) where status == 401 || status == 403 {
				needingSignIn.insert(account.id)
			} catch is SignInError {
				needingSignIn.insert(account.id)
			} catch {
				// A transient failure leaves the previous cache in place.
			}
		}

		guard generation == self.generation else { return }

		courses = fetchedCourses
		assignments = fetchedAssignments
		needsReauthentication = needingSignIn
		settings.pruneCanvasCourseSelection(keeping: Set(fetchedCourses.map(\.id)))
		isRefreshing = false
		onChange?()
	}

	// MARK: - Tokens

	/// Runs `body` with a usable access token, refreshing once if Canvas rejects it.
	private func withValidToken<T: Sendable>(
		for account: CanvasAccount,
		_ body: (String) async throws -> T
	) async throws -> T {
		let token = try await accessToken(for: account)
		do {
			return try await body(token)
		} catch CanvasAPIError.http(let status, _) where status == 401 {
			return try await body(try await refreshToken(for: account))
		}
	}

	private func accessToken(for account: CanvasAccount) async throws -> String {
		guard
			let tokens = try secrets.value(
				CanvasTokens.self,
				for: KeychainStore.Item.tokens(accountID: account.id)
			)
		else { throw SignInError.notSignedIn }

		guard tokens.needsRefresh(at: Date()) else { return tokens.accessToken }
		return try await refreshToken(for: account)
	}

	/// Exchanges the refresh token for a new access token, reusing the same refresh token.
	@discardableResult
	private func refreshToken(for account: CanvasAccount) async throws -> String {
		guard
			let tokens = try secrets.value(
				CanvasTokens.self,
				for: KeychainStore.Item.tokens(accountID: account.id)
			),
			let credentials = try secrets.value(
				CanvasClientCredentials.self,
				for: KeychainStore.Item.client(accountID: account.id)
			)
		else { throw SignInError.notSignedIn }

		let refreshed = try await api.refresh(
			credentials: credentials,
			refreshToken: tokens.refreshToken,
			baseURL: account.baseURL
		)
		try secrets.setValue(refreshed, for: KeychainStore.Item.tokens(accountID: account.id))
		return refreshed.accessToken
	}

	// MARK: - Reminders

	public func reminders(from startDate: Date, to endDate: Date) -> [ReminderEvent] {
		plannedEvents().filter { event in
			event.fireDates.contains { $0 > startDate && $0 <= endDate }
		}
	}

	/// Rebuilt on every read so that editing the rules takes effect without a round trip.
	private func plannedEvents() -> [ReminderEvent] {
		let rules = settings.canvasReminderRules
		guard !rules.isEmpty else { return [] }

		let accountsByID = Dictionary(
			settings.canvasAccounts.map { ($0.id, $0) },
			uniquingKeysWith: { first, _ in first }
		)
		return assignments.compactMap { assignment in
			guard let account = accountsByID[assignment.course.accountID] else { return nil }
			return CanvasReminderPlanner.reminderEvent(
				for: assignment,
				account: account,
				rules: rules,
				calendar: calendar
			)
		}
	}
}
