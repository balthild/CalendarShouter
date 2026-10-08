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

/// Whether the settings window still has to be sized for the pane it is showing.
///
/// A pane change settles from the moment the tab changes until the window has reached the new
/// pane's height, and panes keep their scrollers off for as long as it lasts. SwiftUI creates
/// the new pane's scroll view while the window is still sized for the old one, and a scroll view
/// whose content is momentarily taller than the window draws a scroller — which then vanishes as
/// the resize *starts*, before the window has begun to grow.
///
/// A quick switch back restarts the animation while the previous one is still in flight. Both
/// completions then run, and the earlier one would end the settle — and re-show the scrollers —
/// while the newer pane is still waiting to be sized. Callers therefore pair `beginSettling()`
/// with `settle(_:)` so only the latest pane change's completion ends it.
@MainActor
enum SettingsWindowResize {
	/// True from a tab change until the window has been sized for the pane it is showing.
	private static var isSettling = false

	/// Whether the settle in progress began with a pane change. Only then is the pane on screen a
	/// new one, which has never been scrolled and belongs at its top edge.
	private static var isNewPane = false

	/// Bumped for each settle so a superseded animation's completion can be ignored.
	private static var generation = 0

	/// Whether a pane appearing right now should keep its scroller off.
	static var suppressesScrollers: Bool { isSettling }

	/// Whether the pane on screen was created for the settle in progress.
	///
	/// AppKit scrolls such a pane on its own while it is briefly taller than the window: the form's
	/// layout compensates for the overflow, and a `Table` inside it then asks to be scrolled into
	/// sight. Pinning the pane to its top edge for the settle keeps that from being drawn.
	static var isSettlingNewPane: Bool { isSettling && isNewPane }

	/// Marks the start of a pane change and returns the token its completion passes to `settle(_:)`.
	static func begin(newPane: Bool = false) -> Int {
		generation += 1
		isSettling = true
		isNewPane = newPane
		return generation
	}

	/// Ends the settle if `token` is still the latest pane change; returns whether it did.
	@discardableResult
	static func settle(_ token: Int) -> Bool {
		guard token == generation else { return false }
		isSettling = false
		return true
	}
}
