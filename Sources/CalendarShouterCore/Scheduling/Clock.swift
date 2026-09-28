import Foundation

/// A task scheduled by a `Clock`.
@MainActor
public protocol ScheduledTask: AnyObject {
	func cancel()
}

/// The callback a `Clock` invokes when a scheduled instant arrives.
///
/// It is `@Sendable` so that it can be handed to mechanisms (such as `Timer`)
/// whose blocks cross concurrency domains, while still running on the main actor.
public typealias ClockHandler = @MainActor @Sendable () -> Void

/// Abstracts the passage of time so the scheduler can be tested deterministically.
@MainActor
public protocol Clock: AnyObject {
	var now: Date { get }
	/// Schedules `handler` to run once at `date`.
	func schedule(at date: Date, _ handler: @escaping ClockHandler) -> ScheduledTask
}

/// A `Clock` backed by the real system clock and the main run loop.
@MainActor
public final class SystemClock: Clock {
	private final class TimerTask: ScheduledTask {
		private var timer: Timer?

		init(timer: Timer) {
			self.timer = timer
		}

		func cancel() {
			timer?.invalidate()
			timer = nil
		}
	}

	public init() {}

	public var now: Date { Date() }

	public func schedule(at date: Date, _ handler: @escaping ClockHandler) -> ScheduledTask {
		let timer = Timer(timeInterval: max(0, date.timeIntervalSinceNow), repeats: false) { _ in
			// The main run loop drives this timer, so main-actor isolation holds.
			MainActor.assumeIsolated { handler() }
		}
		// Reminders should appear at the requested instant, not "roughly then".
		timer.tolerance = 0
		RunLoop.main.add(timer, forMode: .common)
		return TimerTask(timer: timer)
	}
}
