import Carbon
import Foundation
import Observation
import ServiceManagement

/// Registers the app as a login item.
///
/// Two mechanisms are available, chosen once at launch:
///
/// - `SMAppService` — the modern interface. It needs the app to carry a real signing
///   identity; an ad-hoc signature has no team identifier, so the service reports
///   `.notFound` and cannot be used.
/// - System Events scripting — `osascript` asks System Events to add the app to the classic
///   login items, which works whatever the signature. Its first call raises the Automation
///   permission prompt, and it is a legacy interface.
///
/// Scripting is used only when `SMAppService` is unavailable, so a properly signed build keeps
/// the supported path. Both need the app to run from a bundle; `swift run` reports `.unavailable`.
@MainActor
@Observable
public final class LoginItemController {
	public enum State: Sendable, Equatable {
		/// The app is not running from a bundle, so the login item cannot be managed.
		case unavailable
		/// The app will not launch at login.
		case disabled
		/// The app will launch at login.
		case enabled
		/// The user must approve the login item in System Settings.
		case requiresApproval
	}

	public private(set) var state: State

	/// Called when enabling the login item leaves it awaiting the user's approval.
	///
	/// `setEnabled(true)` can settle on `.requiresApproval` while the toggle still shows
	/// "off", so the caller is told to guide the user to System Settings.
	public var onApprovalRequired: (() -> Void)?

	/// Called when the scripted login item could not be turned on because the Automation
	/// permission was refused.
	public var onAutomationDenied: (() -> Void)?

	private let mechanism: Mechanism
	private let bundlePath: String
	/// Serialises the scripting calls, which are asynchronous and must not interleave.
	private var scriptTask: Task<Void, Never>?

	public init() {
		let bundlePath = Bundle.main.bundleURL.path
		let mechanism = Self.detectMechanism(bundlePath: bundlePath)
		self.bundlePath = bundlePath
		self.mechanism = mechanism
		self.state = Self.initialState(mechanism: mechanism)
	}

	/// Whether the login item can be managed at all in this environment.
	public var isSupported: Bool { mechanism != .none }

	/// Whether the login item is currently registered.
	public var isEnabled: Bool { state == .enabled }

	public func setEnabled(_ enabled: Bool) {
		guard isSupported else { return }
		switch mechanism {
		case .serviceManagement:
			do {
				if enabled {
					try SMAppService.mainApp.register()
				} else {
					try SMAppService.mainApp.unregister()
				}
			} catch {
				// Registration can fail (for example when the user has denied it);
				// re-reading the status reports whatever the system settled on.
			}
			state = Self.serviceManagementState()
			if enabled, state == .requiresApproval {
				onApprovalRequired?()
			}
		case .loginItemScript:
			applyScriptedEnabled(enabled)
		case .none:
			break
		}
	}

	/// Opens the Login Items section of System Settings.
	public static func openSystemSettingsLoginItems() {
		SMAppService.openSystemSettingsLoginItems()
	}

	public func refresh() {
		switch mechanism {
		case .serviceManagement:
			state = Self.serviceManagementState()
		case .loginItemScript:
			resolveScriptedState()
		case .none:
			state = .unavailable
		}
	}
}

// MARK: - Mechanism

extension LoginItemController {
	private enum Mechanism {
		/// `SMAppService`, which needs a real signing identity.
		case serviceManagement
		/// System Events scripting, which also works for an ad-hoc build.
		case loginItemScript
		case none
	}

	private static func detectMechanism(bundlePath: String) -> Mechanism {
		guard bundlePath.hasSuffix(".app") else { return .none }
		// `.notFound` means the system cannot resolve the app's identity, which is what an
		// ad-hoc signature (no team identifier) produces. Fall back to scripting there.
		return SMAppService.mainApp.status == .notFound ? .loginItemScript : .serviceManagement
	}

	private static func initialState(mechanism: Mechanism) -> State {
		switch mechanism {
		case .serviceManagement:
			return serviceManagementState()
		case .loginItemScript:
			// Deliberately not queried here: the first scripting call raises the Automation
			// prompt, which should wait until the user opens the settings pane.
			return .disabled
		case .none:
			return .unavailable
		}
	}

	private static func serviceManagementState() -> State {
		switch SMAppService.mainApp.status {
		case .notRegistered: return .disabled
		case .enabled: return .enabled
		case .requiresApproval: return .requiresApproval
		case .notFound: return .unavailable
		@unknown default: return .unavailable
		}
	}
}

// MARK: - System Events scripting

extension LoginItemController {
	/// Re-reads the login item state, but only once Automation has been granted.
	///
	/// Reading is itself an Apple event, so asking before permission exists would raise the
	/// prompt merely because the settings pane appeared. Until then the item is reported as
	/// off — which is also true, since it could not have been added without permission.
	private func resolveScriptedState() {
		let previous = scriptTask
		let bundlePath = bundlePath
		scriptTask = Task { @MainActor in
			await previous?.value
			guard Self.hasAutomationPermission else {
				state = .disabled
				return
			}
			state = await Self.scriptedLoginItemState(bundlePath: bundlePath)
		}
	}

	/// Applies the requested state, letting the Automation prompt appear if it has to.
	///
	/// The calls are chained so a toggle and a refresh cannot race.
	private func applyScriptedEnabled(_ enabled: Bool) {
		let previous = scriptTask
		let bundlePath = bundlePath
		scriptTask = Task { @MainActor in
			await previous?.value
			await Self.setScriptedLoginItemEnabled(enabled, bundlePath: bundlePath)

			guard Self.hasAutomationPermission else {
				state = .disabled
				// Only explain a refused *enable*: a refused delete still leaves the item
				// absent, which is what was asked for.
				if enabled {
					onAutomationDenied?()
				}
				return
			}
			state = await Self.scriptedLoginItemState(bundlePath: bundlePath)
		}
	}

	/// Whether this process may send Apple events to System Events.
	///
	/// Checked with `askUserIfNeeded: false`, so it never prompts.
	private static var hasAutomationPermission: Bool {
		var target = AEAddressDesc()
		defer { AEDisposeDesc(&target) }

		let bundleIdentifier = Array("com.apple.systemevents".utf8)
		let created = bundleIdentifier.withUnsafeBufferPointer { buffer in
			AECreateDesc(
				DescType(typeApplicationBundleID),
				buffer.baseAddress,
				buffer.count,
				&target
			)
		}
		guard created == noErr else { return false }

		return AEDeterminePermissionToAutomateTarget(
			&target,
			AEEventClass(kAECoreSuite),
			AEEventID(kAEGetData),
			false
		) == noErr
	}

	private static func scriptedLoginItemState(bundlePath: String) async -> State {
		guard let output = await runLoginItemScript("get the path of every login item") else {
			return .disabled
		}
		let paths = output.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
		return paths.contains(bundlePath) ? .enabled : .disabled
	}

	private static func setScriptedLoginItemEnabled(_ enabled: Bool, bundlePath: String) async {
		// Read first so a stale toggle cannot add a second entry for the same app.
		let isPresent = await scriptedLoginItemState(bundlePath: bundlePath) == .enabled
		guard enabled != isPresent else { return }

		if enabled {
			_ = await runLoginItemScript(
				"make login item at end with properties {path:\"\(bundlePath)\", hidden:false}"
			)
		} else {
			// The item's name is the app's *localized* display name, so it is matched by path.
			// Deleting renumbers the remaining items, hence the reverse walk.
			_ = await runLoginItemScript(
				"""
				set targetPath to "\(bundlePath)"
				repeat with i from (count of login items) to 1 by -1
				if (path of login item i) is targetPath then delete login item i
				end repeat
				"""
			)
		}
	}

	/// Runs `statements` inside a `System Events` tell block, returning its output.
	private static func runLoginItemScript(_ statements: String) async -> String? {
		let script = "tell application \"System Events\"\n\(statements)\nend tell"
		return await Task.detached(priority: .userInitiated) {
			let process = Process()
			process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
			process.arguments = ["-e", script]
			let output = Pipe()
			process.standardOutput = output
			// Discarded: a refused Automation prompt is reported through the exit status.
			process.standardError = Pipe()
			do {
				try process.run()
			} catch {
				return nil
			}
			// Read before waiting, so a full pipe cannot deadlock the child.
			let data = output.fileHandleForReading.readDataToEndOfFile()
			process.waitUntilExit()
			guard process.terminationStatus == 0 else { return nil }
			return String(data: data, encoding: .utf8)?
				.trimmingCharacters(in: .whitespacesAndNewlines)
		}.value
	}
}
