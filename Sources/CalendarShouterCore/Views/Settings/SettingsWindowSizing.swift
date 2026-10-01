import Foundation

/// The metrics shared by every pane.
enum SettingsPaneMetrics {
	static let width: CGFloat = 400

	static let fallbackHeight: CGFloat = 360

	/// The size the settings window is created at, before its content has been laid out.
	static let initialContentSize = NSSize(width: width, height: fallbackHeight)

	/// The tallest the window may grow, as a fraction of the screen's usable height.
	static let maximumHeightFraction: CGFloat = 0.6
}

/// Whether the settings window is animating to a new pane's height.
///
/// A short pane switching to a tall one leaves the content momentarily taller than the
/// window, which would show an overlay scroller that vanishes again when the animation
/// ends. Panes read this when they appear, so a pane created mid-animation keeps its
/// scroller off until the window has settled.
///
/// A quick switch back restarts the animation while the previous one is still in flight.
/// Both completions then run, and the earlier one would clear the flag — and re-show the
/// scrollers — while the later animation is still growing the window, flashing the
/// scroller. Callers therefore pair `begin()` with `end(_:)` so only the latest
/// animation's completion clears the flag.
@MainActor
enum SettingsWindowResize {
	private(set) static var isAnimating = false

	/// Bumped for each resize so a superseded animation's completion can be ignored.
	private static var generation = 0

	/// Marks a resize as started and returns the token its completion passes to `end(_:)`.
	static func begin() -> Int {
		generation += 1
		isAnimating = true
		return generation
	}

	/// Clears the flag if `token` is still the latest resize; returns whether it did.
	@discardableResult
	static func end(_ token: Int) -> Bool {
		guard token == generation else { return false }
		isAnimating = false
		return true
	}
}
