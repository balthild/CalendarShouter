import Foundation
import Testing

@testable import CalendarShouterCore

/// Serves canned responses so the client can be exercised without a network.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
	nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, [String: String], Data))?

	override class func canInit(with request: URLRequest) -> Bool { true }

	override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

	override func startLoading() {
		guard let handler = Self.handler, let url = request.url else {
			client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
			return
		}
		let (status, headers, data) = handler(request)
		guard
			let response = HTTPURLResponse(
				url: url,
				statusCode: status,
				httpVersion: nil,
				headerFields: headers
			)
		else {
			client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
			return
		}
		client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
		client?.urlProtocol(self, didLoad: data)
		client?.urlProtocolDidFinishLoading(self)
	}

	override func stopLoading() {}
}

extension URLRequest {
	/// `URLProtocol` receives a body as a stream, so both spellings have to be consulted.
	var capturedBody: Data? {
		if let httpBody { return httpBody }
		guard let stream = httpBodyStream else { return nil }
		stream.open()
		defer { stream.close() }

		var data = Data()
		let size = 1024
		var buffer = [UInt8](repeating: 0, count: size)
		while stream.hasBytesAvailable {
			let read = stream.read(&buffer, maxLength: size)
			guard read > 0 else { break }
			data.append(buffer, count: read)
		}
		return data
	}
}

/// Serialised because the stub's handler is process-wide.
@Suite("Canvas API client", .serialized)
struct CanvasAPIClientTests {
	private let baseURL = URL(string: "https://canvas.example.edu")!
	private let credentials = CanvasClientCredentials(clientID: "123", clientSecret: "secret")

	private func makeClient() -> URLSessionCanvasAPIClient {
		let configuration = URLSessionConfiguration.ephemeral
		configuration.protocolClasses = [StubURLProtocol.self]
		return URLSessionCanvasAPIClient(session: URLSession(configuration: configuration))
	}

	private func stub(
		status: Int = 200,
		headers: [String: String] = [:],
		_ body: String
	) {
		let data = Data(body.utf8)
		StubURLProtocol.handler = { _ in (status, headers, data) }
	}

	// MARK: - Domain verification

	@Test("A recognised domain yields its base address and credentials")
	func verifySuccess() async throws {
		nonisolated(unsafe) var captured: URLRequest?
		let data = Data(
			"""
			{"authorized":true,"result":0,"client_id":"1700","client_secret":"shh",
			 "api_key":"shh","base_url":"https://canvas.example.edu/"}
			""".utf8
		)
		StubURLProtocol.handler = { request in
			captured = request
			return (200, [:], data)
		}

		let verification = try await makeClient().verifyDomain("canvas.example.edu")

		#expect(verification.result == .success)
		#expect(verification.baseURL == baseURL.appendingPathComponent(""))
		#expect(
			verification.credentials == CanvasClientCredentials(clientID: "1700", clientSecret: "shh")
		)

		// The mobile endpoint only answers clients it recognises, and it reads the header.
		let request = try #require(captured)
		#expect(request.value(forHTTPHeaderField: "User-Agent") == URLSessionCanvasAPIClient.userAgent)
		#expect(request.url?.query?.contains("domain=canvas.example.edu") == true)
	}

	@Test("A domain Canvas does not know about is reported as unauthorised")
	func verifyNotAuthorized() async throws {
		stub(#"{"authorized":false,"result":2}"#)
		let verification = try await makeClient().verifyDomain("example.com")
		#expect(verification.result == .domainNotAuthorized)
		#expect(verification.credentials == nil)
	}

	@Test("An unrecognised user agent is reported as such")
	func verifyUnknownUserAgent() async throws {
		stub(#"{"authorized":false,"result":3}"#)
		let verification = try await makeClient().verifyDomain("canvas.example.edu")
		#expect(verification.result == .unknownUserAgent)
	}

	@Test("A domain with no credentials is not usable even if it is authorised")
	func verifyWithoutCredentials() async throws {
		stub(#"{"authorized":true,"result":0,"base_url":"https://canvas.example.edu/"}"#)
		let verification = try await makeClient().verifyDomain("canvas.example.edu")
		#expect(verification.result == .domainNotAuthorized)
	}

	// MARK: - Tokens

	@Test("An authorization code is exchanged for tokens and a user")
	func authenticate() async throws {
		nonisolated(unsafe) var captured: URLRequest?
		let data = Data(
			"""
			{"access_token":"at","refresh_token":"rt","expires_in":3600,
			 "token_type":"Bearer","user":{"id":7,"name":"Student"}}
			""".utf8
		)
		StubURLProtocol.handler = { request in
			captured = request
			return (200, [:], data)
		}

		let before = Date()
		let result = try await makeClient().authenticate(
			code: "abc",
			credentials: credentials,
			baseURL: baseURL
		)

		#expect(result.tokens.accessToken == "at")
		#expect(result.tokens.refreshToken == "rt")
		#expect(result.tokens.expiresAt.timeIntervalSince(before) >= 3599)
		#expect(result.user == CanvasAuthenticatedUser(id: "7", name: "Student"))

		let request = try #require(captured)
		#expect(request.httpMethod == "POST")
		#expect(request.url?.path == "/login/oauth2/token")

		let body = String(decoding: try #require(request.capturedBody), as: UTF8.self)
		#expect(body.contains("grant_type=authorization_code"))
		#expect(body.contains("code=abc"))
		#expect(body.contains("redirect_uri=https%3A%2F%2Fsso.canvaslms.com%2Fcanvas%2Flogin"))
	}

	@Test("Refreshing keeps the refresh token the response leaves out")
	func refreshKeepsRefreshToken() async throws {
		nonisolated(unsafe) var captured: URLRequest?
		let data = Data(#"{"access_token":"at2","expires_in":3600,"user":{"id":7,"name":"S"}}"#.utf8)
		StubURLProtocol.handler = { request in
			captured = request
			return (200, [:], data)
		}

		let tokens = try await makeClient().refresh(
			credentials: credentials,
			refreshToken: "rt-old",
			baseURL: baseURL
		)

		#expect(tokens.accessToken == "at2")
		#expect(tokens.refreshToken == "rt-old")

		let body = String(decoding: try #require(captured?.capturedBody), as: UTF8.self)
		#expect(body.contains("grant_type=refresh_token"))
		#expect(body.contains("refresh_token=rt-old"))
	}

	@Test("A rejected request surfaces the status and Canvas's explanation")
	func httpFailure() async throws {
		stub(
			status: 400,
			#"{"error":"invalid_grant","error_description":"authorization_code not found"}"#
		)

		await #expect(throws: CanvasAPIError.http(status: 400, message: "authorization_code not found"))
		{
			_ = try await makeClient().authenticate(
				code: "nope",
				credentials: credentials,
				baseURL: baseURL
			)
		}
	}

	// MARK: - Courses and assignments

	@Test("Courses are read with the bearer token and follow pagination")
	func coursesFollowPagination() async throws {
		nonisolated(unsafe) var requestedURLs: [URL] = []
		nonisolated(unsafe) var authorizations: [String?] = []
		let pages = [
			#"[{"id":1,"name":"Algorithms","course_code":"CS301"}]"#,
			#"[{"id":2,"name":"Compilers","course_code":"CS402"}]"#,
		]

		StubURLProtocol.handler = { request in
			requestedURLs.append(request.url!)
			authorizations.append(request.value(forHTTPHeaderField: "Authorization"))
			let isSecondPage = request.url?.query?.contains("page=2") == true
			let headers =
				isSecondPage
				? [:]
				: [
					"Link":
						"<https://canvas.example.edu/api/v1/courses?page=2>; rel=\"next\", <https://canvas.example.edu/api/v1/courses?page=2>; rel=\"last\""
				]
			return (200, headers, Data(pages[isSecondPage ? 1 : 0].utf8))
		}

		let courses = try await makeClient().courses(accessToken: "at", baseURL: baseURL)

		#expect(
			courses == [
				CanvasCourseRecord(id: "1", name: "Algorithms", courseCode: "CS301"),
				CanvasCourseRecord(id: "2", name: "Compilers", courseCode: "CS402"),
			]
		)
		#expect(requestedURLs.count == 2)
		#expect(authorizations == ["Bearer at", "Bearer at"])
		#expect(requestedURLs.first?.path == "/api/v1/courses")
	}

	@Test("Assignments carry their window, due date and submission state")
	func assignments() async throws {
		stub(
			"""
			[
			 {"id":4,"name":"Problem set","due_at":"2026-03-10T23:59:00Z",
			  "unlock_at":"2026-03-01T00:00:00Z","lock_at":"2026-03-11T00:00:00Z",
			  "published":true,"html_url":"https://canvas.example.edu/courses/1/assignments/4",
			  "submission":{"workflow_state":"graded"}},
			 {"id":5,"name":"Essay","due_at":null,"published":false,"submission":null},
			 {"id":6,"name":"Quiz","due_at":"2026-03-12T12:00:00-06:00",
			  "submission":{"workflow_state":"unsubmitted"}}
			]
			"""
		)

		let assignments = try await makeClient().assignments(
			courseID: "1",
			accessToken: "at",
			baseURL: baseURL
		)

		#expect(assignments.count == 3)

		let problemSet = assignments[0]
		#expect(problemSet.isPublished)
		#expect(problemSet.isSubmitted)
		#expect(problemSet.dueAt != nil)
		#expect(problemSet.unlockAt != nil)
		#expect(problemSet.lockAt != nil)
		#expect(problemSet.htmlURL?.lastPathComponent == "4")

		#expect(!assignments[1].isPublished)
		#expect(assignments[1].dueAt == nil)
		#expect(!assignments[2].isSubmitted)
	}
}
