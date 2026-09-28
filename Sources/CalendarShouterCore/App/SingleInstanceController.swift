import Darwin
import Foundation

/// Ensures only one copy of the app runs at a time.
///
/// A bundled app is already protected by `LSMultipleInstancesProhibited`, which
/// makes LaunchServices activate the running copy instead of starting a second.
/// When the binary is launched directly (for example by `swift run`) that
/// protection does not apply, so an advisory file lock is used as well: the
/// second process asks the first to show its settings window and then exits.
@MainActor
public final class SingleInstanceController {
	/// Distributed notification asking the primary instance to show its settings.
	public static let showSettingsNotification = Notification.Name(
		"com.balthild.CalendarShouter.showSettings"
	)

	/// How long a secondary instance waits for the primary to react before exiting.
	public static let handoffDelay: TimeInterval = 0.5

	private let lockFileURL: URL
	/// Held open for the lifetime of the process; closing it releases the lock.
	private var lockFileDescriptor: Int32 = -1
	nonisolated(unsafe) private var showSettingsObserver: NSObjectProtocol?

	public init(lockFileURL: URL? = nil) {
		self.lockFileURL = lockFileURL ?? Self.defaultLockFileURL
	}

	deinit {
		if let showSettingsObserver {
			DistributedNotificationCenter.default().removeObserver(showSettingsObserver)
		}
		if lockFileDescriptor >= 0 {
			close(lockFileDescriptor)
		}
	}

	/// The lock file used to detect other instances.
	public static var defaultLockFileURL: URL {
		let base =
			FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
			?? FileManager.default.temporaryDirectory
		let directory = base.appendingPathComponent("CalendarShouter", isDirectory: true)
		try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		return directory.appendingPathComponent("instance.lock")
	}

	/// Acquires the instance lock, returning `true` when this is the only instance.
	///
	/// If the lock cannot be taken at all, the app proceeds rather than refusing to
	/// start, since being unable to write a lock file is not a reason to fail.
	public func acquirePrimaryInstance() -> Bool {
		let descriptor = open(lockFileURL.path, O_CREAT | O_RDWR, 0o644)
		guard descriptor >= 0 else { return true }
		guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
			close(descriptor)
			return false
		}
		lockFileDescriptor = descriptor
		return true
	}

	/// Asks the already-running instance to show its settings window.
	public func requestPrimaryInstanceToShowSettings() {
		DistributedNotificationCenter.default().postNotificationName(
			Self.showSettingsNotification,
			object: nil,
			userInfo: nil,
			deliverImmediately: true
		)
	}

	/// Handles requests from a secondary instance that is about to exit.
	public func observeShowSettingsRequests(_ handler: @escaping @MainActor @Sendable () -> Void) {
		showSettingsObserver = DistributedNotificationCenter.default().addObserver(
			forName: Self.showSettingsNotification,
			object: nil,
			queue: .main
		) { _ in
			// Registered on the main queue.
			MainActor.assumeIsolated { handler() }
		}
	}
}
