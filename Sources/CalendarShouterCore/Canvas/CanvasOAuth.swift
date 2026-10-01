import Foundation

/// An identifier that Canvas may send as a number or as a string, depending on the endpoint.
///
/// Course and assignment ids are numbers, but the mobile endpoints quote some of them, so
/// they are kept as text and compared as text.
public struct CanvasID: Sendable, Equatable, Hashable, Codable, CustomStringConvertible {
	public let rawValue: String

	public init(_ rawValue: String) {
		self.rawValue = rawValue
	}

	public init(from decoder: Decoder) throws {
		let container = try decoder.singleValueContainer()
		if let text = try? container.decode(String.self) {
			rawValue = text
		} else if let number = try? container.decode(Int.self) {
			rawValue = String(number)
		} else {
			throw DecodingError.typeMismatch(
				String.self,
				DecodingError.Context(
					codingPath: decoder.codingPath,
					debugDescription: "Expected a Canvas id as a string or a number"
				)
			)
		}
	}

	public func encode(to encoder: Encoder) throws {
		var container = encoder.singleValueContainer()
		try container.encode(rawValue)
	}

	public var description: String { rawValue }
}

/// The OAuth credentials Canvas issues for a domain.
///
/// These belong to the institution's registered mobile app, are fetched per domain at
/// sign-in, and are needed again every time the access token is refreshed.
public struct CanvasClientCredentials: Sendable, Equatable, Codable {
	public let clientID: String
	public let clientSecret: String

	public init(clientID: String, clientSecret: String) {
		self.clientID = clientID
		self.clientSecret = clientSecret
	}
}

/// An account's OAuth tokens.
public struct CanvasTokens: Sendable, Equatable, Codable {
	public var accessToken: String
	public let refreshToken: String
	public let expiresAt: Date

	public init(accessToken: String, refreshToken: String, expiresAt: Date) {
		self.accessToken = accessToken
		self.refreshToken = refreshToken
		self.expiresAt = expiresAt
	}

	/// Whether the access token is close enough to expiry to be worth refreshing first.
	public func needsRefresh(at date: Date, leeway: TimeInterval = 60) -> Bool {
		date.addingTimeInterval(leeway) >= expiresAt
	}
}

/// What Canvas says about a domain before anyone signs in.
public struct CanvasDomainVerification: Sendable, Equatable {
	/// Mirrors the `result` code the mobile verification endpoint returns.
	public enum Result: Sendable, Equatable {
		case success
		case generalError
		/// The domain is not a Canvas install, or its mobile app access is switched off.
		case domainNotAuthorized
		/// The request did not identify itself as a supported client.
		case unknownUserAgent
		case unknown

		init(code: Int) {
			switch code {
			case 0: self = .success
			case 1: self = .generalError
			case 2: self = .domainNotAuthorized
			case 3: self = .unknownUserAgent
			default: self = .unknown
			}
		}
	}

	public let result: Result
	public let baseURL: URL?
	public let credentials: CanvasClientCredentials?

	public init(result: Result, baseURL: URL?, credentials: CanvasClientCredentials?) {
		self.result = result
		self.baseURL = baseURL
		self.credentials = credentials
	}
}

/// Where the OAuth dance starts and where Canvas sends the user back.
public enum CanvasOAuth {
	/// The redirect Canvas has registered for its mobile clients.
	///
	/// It is an ordinary HTTPS address rather than a custom scheme, so the code arrives as a
	/// navigation in a web view instead of by opening the app.
	public static let redirectURI = "https://sso.canvaslms.com/canvas/login"
	public static let callbackHost = "sso.canvaslms.com"
	public static let callbackPath = "/canvas/login"

	/// The address the user is sent to in order to grant access.
	public static func authorizationURL(domain: String, credentials: CanvasClientCredentials) -> URL?
	{
		var components = URLComponents()
		components.scheme = "https"
		components.host = domain
		components.path = "/login/oauth2/auth"
		components.queryItems = [
			URLQueryItem(name: "client_id", value: credentials.clientID),
			URLQueryItem(name: "response_type", value: "code"),
			URLQueryItem(name: "redirect_uri", value: redirectURI),
			URLQueryItem(name: "mobile", value: "1"),
		]
		return components.url
	}

	/// Whether a navigation is Canvas handing the authorization code back.
	public static func isCallback(_ url: URL) -> Bool {
		url.host == callbackHost && url.path == callbackPath
	}

	public static func authorizationCode(from url: URL) -> String? {
		guard isCallback(url) else { return nil }
		return URLComponents(url: url, resolvingAgainstBaseURL: false)?
			.queryItems?
			.first { $0.name == "code" }?
			.value
	}

	public static func error(from url: URL) -> String? {
		guard isCallback(url) else { return nil }
		return URLComponents(url: url, resolvingAgainstBaseURL: false)?
			.queryItems?
			.first { $0.name == "error" }?
			.value
	}

	/// Reduces whatever the user typed to a bare host.
	///
	/// Accepts a full address as readily as a hostname, because people paste whichever one
	/// their institution handed them.
	public static func normalizedDomain(_ input: String) -> String? {
		var text = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
		guard !text.isEmpty else { return nil }

		for prefix in ["https://", "http://"] where text.hasPrefix(prefix) {
			text.removeFirst(prefix.count)
		}
		text = text.split(separator: "/").first.map(String.init) ?? text
		text = text.split(separator: ":").first.map(String.init) ?? text
		guard text.contains("."), !text.hasPrefix("."), !text.hasSuffix(".") else { return nil }
		guard text.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" }) else {
			return nil
		}
		return text
	}
}
