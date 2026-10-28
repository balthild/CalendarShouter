import AppKit
import SwiftUI

/// Shows the reminders that are due soonest in a borderless, translucent panel.
///
/// The panel is a read-only overview: reminders themselves are still presented one by one
/// when they come due, so nothing here changes the scheduler's state.
@MainActor
public final class UpcomingRemindersWindowController {
	static let panelWidth: CGFloat = 380

	private var panel: NSPanel?

	public init() {}

	/// Shows `fires`, replacing a panel that is already open.
	public func present(_ fires: [ReminderFire]) {
		close()

		let panel = UpcomingPanel(
			contentRect: NSRect(x: 0, y: 0, width: Self.panelWidth, height: 200),
			styleMask: [.borderless, .nonactivatingPanel],
			backing: .buffered,
			defer: false
		)
		panel.onCancel = { [weak self] in self?.close() }

		TranslucentPanel.configure(
			panel,
			content: UpcomingRemindersView(
				fires: fires,
				onClose: { [weak self] in self?.close() }
			),
			width: Self.panelWidth
		)
		TranslucentPanel.center(panel)
		TranslucentPanel.fadeIn(panel)

		self.panel = panel
	}

	/// Closes the panel if it is open.
	public func close() {
		panel?.close()
		panel = nil
	}
}

/// A panel that closes on Escape.
private final class UpcomingPanel: NSPanel {
	var onCancel: (() -> Void)?

	override var canBecomeKey: Bool { true }
	override var canBecomeMain: Bool { false }

	override func cancelOperation(_ sender: Any?) {
		onCancel?()
	}
}
