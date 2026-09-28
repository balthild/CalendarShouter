import Foundation

/// Caps how often a sound may play, so a burst of reminders does not become a burst
/// of noise. Every reminder itself is still shown.
public struct SoundRateLimiter {
	/// The most sounds allowed within one window.
	public let limit: Int
	/// The length of the window, in seconds.
	public let window: TimeInterval

	private var windowStart: Date?
	private var playCount = 0

	public init(limit: Int = 5, window: TimeInterval = 60) {
		self.limit = limit
		self.window = window
	}

	/// Whether a sound may play at `date`, counting the play if so.
	public mutating func shouldPlay(at date: Date) -> Bool {
		if let windowStart, date.timeIntervalSince(windowStart) < window {
			guard playCount < limit else { return false }
			playCount += 1
			return true
		}
		windowStart = date
		playCount = 1
		return true
	}
}
