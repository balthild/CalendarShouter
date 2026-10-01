import Foundation

/// What the API hands back for a course, before it is tied to an account.
public struct CanvasCourseRecord: Sendable, Equatable {
	public let id: String
	public let name: String
	public let courseCode: String?

	public init(id: String, name: String, courseCode: String?) {
		self.id = id
		self.name = name
		self.courseCode = courseCode
	}
}

/// What the API hands back for an assignment, before it is tied to a course.
public struct CanvasAssignmentRecord: Sendable, Equatable {
	public let id: String
	public let name: String
	public let dueAt: Date?
	public let unlockAt: Date?
	public let lockAt: Date?
	public let isPublished: Bool
	public let isSubmitted: Bool
	public let htmlURL: URL?

	public init(
		id: String,
		name: String,
		dueAt: Date?,
		unlockAt: Date?,
		lockAt: Date?,
		isPublished: Bool,
		isSubmitted: Bool,
		htmlURL: URL?
	) {
		self.id = id
		self.name = name
		self.dueAt = dueAt
		self.unlockAt = unlockAt
		self.lockAt = lockAt
		self.isPublished = isPublished
		self.isSubmitted = isSubmitted
		self.htmlURL = htmlURL
	}
}

/// A signed-in user, as the token endpoint reports it.
public struct CanvasAuthenticatedUser: Sendable, Equatable {
	public let id: String
	public let name: String

	public init(id: String, name: String) {
		self.id = id
		self.name = name
	}
}

public enum CanvasAPIError: Error, Equatable {
	case invalidURL
	case invalidResponse
	case http(status: Int, message: String?)
	case decoding
}

/// The Canvas endpoints the app talks to.
///
/// Split out as a protocol so the service above it can be driven by a stub, since none of
/// the reminder logic should need a network to be testable.
public protocol CanvasAPIClient: Sendable {
	func verifyDomain(_ domain: String) async throws -> CanvasDomainVerification

	func authenticate(
		code: String,
		credentials: CanvasClientCredentials,
		baseURL: URL
	) async throws -> (tokens: CanvasTokens, user: CanvasAuthenticatedUser)

	func refresh(
		credentials: CanvasClientCredentials,
		refreshToken: String,
		baseURL: URL
	) async throws -> CanvasTokens

	func courses(accessToken: String, baseURL: URL) async throws -> [CanvasCourseRecord]

	func assignments(
		courseID: String,
		accessToken: String,
		baseURL: URL
	) async throws -> [CanvasAssignmentRecord]
}

/// The live client.
public final class URLSessionCanvasAPIClient: CanvasAPIClient, @unchecked Sendable {
	/// The identity Canvas requires before it will hand over a domain's client credentials.
	///
	/// The mobile verification endpoint only recognises its own clients, and the version is
	/// not part of what it checks, so this is a constant rather than something the user
	/// supplies. It names the iOS student app because this is an Apple-platform client.
	public static let userAgent = "iCanvas/7.24.0 (724000) iPhone/iOS 18.5"

	private static let verificationURL = URL(
		string: "https://sso.canvaslms.com/api/v1/mobile_verify.json"
	)!

	private let session: URLSession
	private let pageLimit = 50

	public init(session: URLSession = .shared) {
		self.session = session
	}

	// MARK: - Domain verification

	public func verifyDomain(_ domain: String) async throws -> CanvasDomainVerification {
		var components = URLComponents(url: Self.verificationURL, resolvingAgainstBaseURL: false)
		components?.queryItems = [URLQueryItem(name: "domain", value: domain)]
		guard let url = components?.url else { throw CanvasAPIError.invalidURL }

		var request = URLRequest(url: url)
		request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
		request.setValue("application/json", forHTTPHeaderField: "Accept")

		let (data, response) = try await session.data(for: request)
		try Self.validate(response, data: data)

		let payload: DomainVerificationPayload
		do {
			payload = try JSONDecoder().decode(DomainVerificationPayload.self, from: data)
		} catch {
			throw CanvasAPIError.decoding
		}

		let baseURL = payload.baseURL.flatMap { $0.isEmpty ? nil : URL(string: $0) }
		let credentials = payload.clientID.flatMap { clientID in
			payload.clientSecret.map { CanvasClientCredentials(clientID: clientID, clientSecret: $0) }
		}

		let result: CanvasDomainVerification.Result
		if payload.result == 0 {
			// A success that arrives without credentials cannot be signed in to.
			result = (baseURL != nil && credentials != nil) ? .success : .domainNotAuthorized
		} else {
			result = CanvasDomainVerification.Result(code: payload.result)
		}
		return CanvasDomainVerification(result: result, baseURL: baseURL, credentials: credentials)
	}

	// MARK: - OAuth

	public func authenticate(
		code: String,
		credentials: CanvasClientCredentials,
		baseURL: URL
	) async throws -> (tokens: CanvasTokens, user: CanvasAuthenticatedUser) {
		let payload = try await tokenRequest(
			baseURL: baseURL,
			fields: [
				"grant_type": "authorization_code",
				"client_id": credentials.clientID,
				"client_secret": credentials.clientSecret,
				"redirect_uri": CanvasOAuth.redirectURI,
				"code": code,
			]
		)
		guard let refreshToken = payload.refreshToken else { throw CanvasAPIError.decoding }
		return (
			tokens: payload.tokens(refreshToken: refreshToken),
			user: CanvasAuthenticatedUser(id: payload.user.id.rawValue, name: payload.user.name)
		)
	}

	public func refresh(
		credentials: CanvasClientCredentials,
		refreshToken: String,
		baseURL: URL
	) async throws -> CanvasTokens {
		let payload = try await tokenRequest(
			baseURL: baseURL,
			fields: [
				"grant_type": "refresh_token",
				"client_id": credentials.clientID,
				"client_secret": credentials.clientSecret,
				"refresh_token": refreshToken,
			]
		)
		// A refresh response carries no new refresh token; the original is reused.
		return payload.tokens(refreshToken: payload.refreshToken ?? refreshToken)
	}

	private func tokenRequest(baseURL: URL, fields: [String: String]) async throws -> TokenPayload {
		guard let url = URL(string: "login/oauth2/token", relativeTo: baseURL) else {
			throw CanvasAPIError.invalidURL
		}
		var request = URLRequest(url: url)
		request.httpMethod = "POST"
		request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
		request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
		request.httpBody = Self.formEncode(fields).data(using: .utf8)

		let (data, response) = try await session.data(for: request)
		try Self.validate(response, data: data)

		do {
			return try Self.decoder().decode(TokenPayload.self, from: data)
		} catch {
			throw CanvasAPIError.decoding
		}
	}

	// MARK: - Data

	public func courses(accessToken: String, baseURL: URL) async throws -> [CanvasCourseRecord] {
		guard
			let url = URL(
				string: "api/v1/courses?per_page=100&enrollment_state=active",
				relativeTo: baseURL
			)
		else { throw CanvasAPIError.invalidURL }

		let payloads: [CoursePayload] = try await getAll(url, accessToken: accessToken)
		return payloads.map {
			CanvasCourseRecord(
				id: $0.id.rawValue,
				name: $0.name ?? $0.courseCode ?? "Course \($0.id.rawValue)",
				courseCode: $0.courseCode
			)
		}
	}

	public func assignments(
		courseID: String,
		accessToken: String,
		baseURL: URL
	) async throws -> [CanvasAssignmentRecord] {
		let encodedID =
			courseID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? courseID
		guard
			let url = URL(
				string: "api/v1/courses/\(encodedID)/assignments?per_page=100&include[]=submission",
				relativeTo: baseURL
			)
		else { throw CanvasAPIError.invalidURL }

		let payloads: [AssignmentPayload] = try await getAll(url, accessToken: accessToken)
		return payloads.map { payload in
			CanvasAssignmentRecord(
				id: payload.id.rawValue,
				name: payload.name ?? "Assignment \(payload.id.rawValue)",
				dueAt: payload.dueAt,
				unlockAt: payload.unlockAt,
				lockAt: payload.lockAt,
				isPublished: payload.isPublished,
				isSubmitted: payload.isSubmitted,
				htmlURL: payload.htmlURL
			)
		}
	}

	/// Follows Canvas's `Link` pagination to the end.
	private func getAll<Payload: Decodable>(_ url: URL, accessToken: String) async throws -> [Payload]
	{
		var collected: [Payload] = []
		var next: URL? = url
		var pages = 0

		while let pageURL = next, pages < pageLimit {
			pages += 1

			var request = URLRequest(url: pageURL)
			request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
			request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
			request.setValue("application/json", forHTTPHeaderField: "Accept")

			let (data, response) = try await session.data(for: request)
			try Self.validate(response, data: data)

			do {
				collected.append(contentsOf: try Self.decoder().decode([Payload].self, from: data))
			} catch {
				throw CanvasAPIError.decoding
			}
			next = Self.nextPageURL(from: response)
		}
		return collected
	}

	// MARK: - Helpers

	private static func validate(_ response: URLResponse, data: Data) throws {
		guard let http = response as? HTTPURLResponse else { throw CanvasAPIError.invalidResponse }
		guard (200..<300).contains(http.statusCode) else {
			throw CanvasAPIError.http(status: http.statusCode, message: errorMessage(from: data))
		}
	}

	private static func errorMessage(from data: Data) -> String? {
		struct OAuthError: Decodable {
			let error: String?
			let errorDescription: String?
			enum CodingKeys: String, CodingKey {
				case error
				case errorDescription = "error_description"
			}
		}
		if let payload = try? JSONDecoder().decode(OAuthError.self, from: data) {
			return payload.errorDescription ?? payload.error
		}
		return nil
	}

	/// Reads the address of the next page out of the `Link` header.
	private static func nextPageURL(from response: URLResponse) -> URL? {
		guard let header = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Link") else {
			return nil
		}
		for link in header.split(separator: ",") {
			let parts = link.split(separator: ";")
			guard parts.contains(where: { $0.contains("rel=\"next\"") }) else { continue }
			guard let start = link.firstIndex(of: "<"), let end = link.firstIndex(of: ">"), start < end
			else {
				continue
			}
			return URL(string: String(link[link.index(after: start)..<end]))
		}
		return nil
	}

	private static func formEncode(_ fields: [String: String]) -> String {
		var allowed = CharacterSet.alphanumerics
		allowed.insert(charactersIn: "-._~")
		return
			fields
			.sorted { $0.key < $1.key }
			.map { key, value in
				let encodedKey = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
				let encodedValue = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
				return "\(encodedKey)=\(encodedValue)"
			}
			.joined(separator: "&")
	}

	/// Canvas writes timestamps as ISO 8601, sometimes with fractional seconds.
	private static func decoder() -> JSONDecoder {
		let decoder = JSONDecoder()
		decoder.dateDecodingStrategy = .custom { decoder in
			let text = try decoder.singleValueContainer().decode(String.self)
			if let date = ISO8601.withFraction.date(from: text) { return date }
			if let date = ISO8601.withoutFraction.date(from: text) { return date }
			throw DecodingError.dataCorrupted(
				DecodingError.Context(
					codingPath: decoder.codingPath,
					debugDescription: "Unrecognised date \(text)"
				)
			)
		}
		return decoder
	}
}

/// The two spellings of an ISO 8601 timestamp Canvas can send.
private enum ISO8601 {
	/// `ISO8601DateFormatter` is not `Sendable`, but reading one from several threads is
	/// safe in practice; the opt-out is needed only because a decoding strategy's closure
	/// is `@Sendable`.
	nonisolated(unsafe) static let withFraction: ISO8601DateFormatter = {
		let formatter = ISO8601DateFormatter()
		formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
		return formatter
	}()

	nonisolated(unsafe) static let withoutFraction: ISO8601DateFormatter = {
		let formatter = ISO8601DateFormatter()
		formatter.formatOptions = [.withInternetDateTime]
		return formatter
	}()
}

// MARK: - Wire formats

private struct DomainVerificationPayload: Decodable {
	let authorized: Bool
	let result: Int
	let clientID: String?
	let clientSecret: String?
	let baseURL: String?

	enum CodingKeys: String, CodingKey {
		case authorized, result
		case clientID = "client_id"
		case clientSecret = "client_secret"
		case baseURL = "base_url"
	}
}

private struct TokenPayload: Decodable {
	let accessToken: String
	let refreshToken: String?
	let expiresIn: TimeInterval?
	let user: User

	struct User: Decodable {
		let id: CanvasID
		let name: String
	}

	enum CodingKeys: String, CodingKey {
		case user
		case accessToken = "access_token"
		case refreshToken = "refresh_token"
		case expiresIn = "expires_in"
	}

	func tokens(refreshToken: String) -> CanvasTokens {
		CanvasTokens(
			accessToken: accessToken,
			refreshToken: refreshToken,
			expiresAt: Date().addingTimeInterval(expiresIn ?? 3600)
		)
	}
}

private struct CoursePayload: Decodable {
	let id: CanvasID
	let name: String?
	let courseCode: String?

	enum CodingKeys: String, CodingKey {
		case id, name
		case courseCode = "course_code"
	}
}

private struct AssignmentPayload: Decodable {
	let id: CanvasID
	let name: String?
	let dueAt: Date?
	let unlockAt: Date?
	let lockAt: Date?
	let published: Bool?
	let workflowState: String?
	let htmlURL: URL?
	let submission: Submission?

	struct Submission: Decodable {
		let workflowState: String?

		enum CodingKeys: String, CodingKey {
			case workflowState = "workflow_state"
		}
	}

	enum CodingKeys: String, CodingKey {
		case id, name, published, submission
		case dueAt = "due_at"
		case unlockAt = "unlock_at"
		case lockAt = "lock_at"
		case workflowState = "workflow_state"
		case htmlURL = "html_url"
	}

	var isPublished: Bool {
		if let published { return published }
		return workflowState == "published" || workflowState == "available"
	}

	/// "graded" and "pending_review" both mean the student already handed something in.
	var isSubmitted: Bool {
		switch submission?.workflowState {
		case "submitted", "graded", "pending_review": true
		default: false
		}
	}
}
