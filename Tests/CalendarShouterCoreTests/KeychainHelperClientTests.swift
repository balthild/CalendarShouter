import Foundation
import Testing

@testable import CalendarShouterCore

/// Records what the client asked the helper to do and returns a scripted result, so the
/// status-to-error mapping can be exercised without a signed bundle or a real keychain.
private final class ScriptedHelper: @unchecked Sendable {
	struct Call: Equatable {
		let op: String
		let key: String
		let value: Data?
	}

	var calls: [Call] = []
	var result: (status: Int32, output: Data, message: String) = (0, Data(), "")

	func client(service: String = "com.balthild.CalendarShouter") -> KeychainHelperClient {
		KeychainHelperClient(service: service) { [self] op, key, value in
			calls.append(Call(op: op, key: key, value: value))
			return result
		}
	}
}

@Suite("Keychain helper client")
struct KeychainHelperClientTests {
	@Test("A read returns the helper's payload")
	func readReturnsPayload() throws {
		let helper = ScriptedHelper()
		helper.result = (0, Data("token".utf8), "")
		let store = helper.client()

		#expect(try store.data(for: "k") == Data("token".utf8))
		#expect(helper.calls == [.init(op: "read", key: "k", value: nil)])
	}

	@Test("A missing item is nil, not an error")
	func readMissingIsNil() throws {
		let helper = ScriptedHelper()
		helper.result = (44, Data(), "not-found")

		#expect(try helper.client().data(for: "k") == nil)
	}

	@Test("An unauthenticated read is reported as such")
	func readUnauthenticated() {
		let helper = ScriptedHelper()
		helper.result = (77, Data(), "caller did not authenticate")

		#expect(throws: KeychainHelperClient.Failure.unauthenticated) {
			_ = try helper.client().data(for: "k")
		}
	}

	@Test("Any other status carries its message through")
	func readOtherFailure() {
		let helper = ScriptedHelper()
		helper.result = (1, Data(), "SecItemCopyMatching: -25300")

		#expect(throws: KeychainHelperClient.Failure.failed(1, "SecItemCopyMatching: -25300")) {
			_ = try helper.client().data(for: "k")
		}
	}

	@Test("A write sends the value on stdin and expects success")
	func writeSendsValue() throws {
		let helper = ScriptedHelper()
		helper.result = (0, Data("ok\n".utf8), "")
		let store = helper.client()

		try store.set(Data("secret".utf8), for: "k")

		#expect(helper.calls == [.init(op: "add", key: "k", value: Data("secret".utf8))])
	}

	@Test("A rejected write fails")
	func writeFailure() {
		let helper = ScriptedHelper()
		helper.result = (1, Data(), "SecItemAdd: -25308")

		#expect(throws: KeychainHelperClient.Failure.failed(1, "SecItemAdd: -25308")) {
			try helper.client().set(Data("secret".utf8), for: "k")
		}
	}

	@Test("Deleting treats a missing item as success")
	func deleteMissingIsFine() throws {
		let helper = ScriptedHelper()
		helper.result = (44, Data(), "")

		try helper.client().removeValue(for: "k")

		#expect(helper.calls == [.init(op: "delete", key: "k", value: nil)])
	}

	@Test("An unauthenticated delete is reported as such")
	func deleteUnauthenticated() {
		let helper = ScriptedHelper()
		helper.result = (77, Data(), "")

		#expect(throws: KeychainHelperClient.Failure.unauthenticated) {
			try helper.client().removeValue(for: "k")
		}
	}
}
