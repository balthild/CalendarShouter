import Darwin
import Foundation

/// Talks to `CalendarShouterKeychainHelper` instead of touching the keychain directly.
///
/// The item's access control names the helper because the app's own code hash changes on every
/// build. See `Tools/KeychainHelper/main.c` for why that matters and for the caller check the
/// helper performs — this side supplies the audit token it verifies.
///
/// Each call spawns the helper for one operation. Canvas touches the keychain a handful of times
/// per session, so the process cost is irrelevant next to the simplicity of not keeping a
/// connection alive.
public struct KeychainHelperClient: SecretStore {
	public enum Failure: Error, Equatable, CustomStringConvertible {
		case helperUnavailable
		case spawnFailed(String)
		case unauthenticated
		case failed(Int32, String)

		public var description: String {
			switch self {
			case .helperUnavailable:
				return "The keychain helper is not in the app bundle"
			case .spawnFailed(let reason):
				return "Could not start the keychain helper: \(reason)"
			case .unauthenticated:
				return "The keychain helper did not recognise this app"
			case .failed(let status, let message):
				return "The keychain helper failed (\(status)): \(message)"
			}
		}
	}

	/// Runs one helper invocation. Injectable so the status-to-error mapping can be tested without
	/// a signed bundle or a real keychain.
	typealias Run = @Sendable (_ op: String, _ key: String, _ value: Data?) throws -> (
		status: Int32, output: Data, message: String
	)

	private static let helperName = "CalendarShouterKeychainHelper"

	private let service: String
	private let run: Run

	public init(service: String = "com.balthild.CalendarShouter") {
		self.service = service
		self.run = { op, key, value in
			try Self.spawn(service: service, op: op, key: key, value: value)
		}
	}

	init(service: String, run: @escaping Run) {
		self.service = service
		self.run = run
	}

	public func data(for key: String) throws -> Data? {
		let result = try run("read", key, nil)
		switch result.status {
		case 0: return result.output
		case 44: return nil
		case 77: throw Failure.unauthenticated
		default: throw Failure.failed(result.status, result.message)
		}
	}

	public func set(_ data: Data, for key: String) throws {
		let result = try run("add", key, data)
		guard result.status == 0 else { throw Failure.failed(result.status, result.message) }
	}

	public func removeValue(for key: String) throws {
		let result = try run("delete", key, nil)
		if result.status == 77 { throw Failure.unauthenticated }
		guard result.status == 0 || result.status == 44 else {
			throw Failure.failed(result.status, result.message)
		}
	}

	private static func spawn(
		service: String,
		op: String,
		key: String,
		value: Data?
	) throws -> (status: Int32, output: Data, message: String) {
		guard let helper = helperURL() else { throw Failure.helperUnavailable }

		let process = Process()
		process.executableURL = helper
		process.arguments = [op, service, key, auditTokenHex()]

		let input = Pipe()
		let output = Pipe()
		let errors = Pipe()
		process.standardInput = input
		process.standardOutput = output
		process.standardError = errors

		do {
			try process.run()
		} catch {
			throw Failure.spawnFailed(error.localizedDescription)
		}

		if let value { input.fileHandleForWriting.write(value) }
		try? input.fileHandleForWriting.close()

		// The payloads are a few hundred bytes, so draining the pipes in order cannot deadlock.
		let out = output.fileHandleForReading.readDataToEndOfFile()
		let err = errors.fileHandleForReading.readDataToEndOfFile()
		process.waitUntilExit()

		return (
			process.terminationStatus, out,
			String(decoding: err, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
		)
	}

	private static func helperURL() -> URL? {
		guard let executable = Bundle.main.executableURL else { return nil }
		let url = executable.deletingLastPathComponent().appendingPathComponent(helperName)
		return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
	}

	/// The current process's audit token, hex-encoded as eight 32-bit words. The helper resolves it
	/// with the kernel and checks the signature; the token itself is not a secret.
	private static func auditTokenHex() -> String {
		var token = audit_token_t()
		var count = mach_msg_type_number_t(
			MemoryLayout<audit_token_t>.size / MemoryLayout<natural_t>.size
		)
		withUnsafeMutablePointer(to: &token) { pointer in
			pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
				_ = task_info(mach_task_self_, task_flavor_t(TASK_AUDIT_TOKEN), rebound, &count)
			}
		}
		return withUnsafeBytes(of: token) { raw in
			raw.bindMemory(to: UInt32.self).map { String(format: "%08x", $0) }.joined()
		}
	}
}
