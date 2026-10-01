import Foundation
import Testing

@testable import CalendarShouterCore

@Suite("Canvas OAuth")
struct CanvasOAuthTests {
	private let credentials = CanvasClientCredentials(clientID: "123", clientSecret: "secret")

	@Test("The authorization address carries what Canvas expects")
	func authorizationURL() throws {
		let url = try #require(
			CanvasOAuth.authorizationURL(domain: "canvas.example.edu", credentials: credentials)
		)
		let items = try #require(
			URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
		)

		#expect(url.host == "canvas.example.edu")
		#expect(url.path == "/login/oauth2/auth")
		#expect(items.contains(URLQueryItem(name: "client_id", value: "123")))
		#expect(items.contains(URLQueryItem(name: "response_type", value: "code")))
		#expect(items.contains(URLQueryItem(name: "mobile", value: "1")))
		#expect(
			items.contains(URLQueryItem(name: "redirect_uri", value: CanvasOAuth.redirectURI))
		)
	}

	@Test("The redirect back to Canvas carries the code")
	func authorizationCode() throws {
		let url = try #require(
			URL(string: "https://sso.canvaslms.com/canvas/login?code=abc123&state=xyz")
		)
		#expect(CanvasOAuth.isCallback(url))
		#expect(CanvasOAuth.authorizationCode(from: url) == "abc123")
	}

	@Test("A refused authorization is reported as an error, not a code")
	func refusal() throws {
		let url = try #require(
			URL(string: "https://sso.canvaslms.com/canvas/login?error=access_denied")
		)
		#expect(CanvasOAuth.authorizationCode(from: url) == nil)
		#expect(CanvasOAuth.error(from: url) == "access_denied")
	}

	@Test("Any other address is left alone")
	func otherURLs() throws {
		let url = try #require(URL(string: "https://canvas.example.edu/login?code=abc"))
		#expect(!CanvasOAuth.isCallback(url))
		#expect(CanvasOAuth.authorizationCode(from: url) == nil)
	}

	@Test(
		"A typed address is reduced to its host",
		arguments: [
			("canvas.illinoisstate.edu", "canvas.illinoisstate.edu"),
			("  CANVAS.IllinoisState.edu  ", "canvas.illinoisstate.edu"),
			("https://canvas.illinoisstate.edu/", "canvas.illinoisstate.edu"),
			("http://canvas.illinoisstate.edu/courses", "canvas.illinoisstate.edu"),
			("canvas.illinoisstate.edu:443", "canvas.illinoisstate.edu"),
		]
	)
	func normalisingDomains(input: String, expected: String) {
		#expect(CanvasOAuth.normalizedDomain(input) == expected)
	}

	@Test(
		"Something that is not a host is refused",
		arguments: ["", "   ", "localhost", ".edu", "a b.com"]
	)
	func rejectingDomains(input: String) {
		#expect(CanvasOAuth.normalizedDomain(input) == nil)
	}
}
