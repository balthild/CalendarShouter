import AppKit
import SwiftUI

/// Presents reminders as borderless, translucent panels that float above other
/// windows.
@MainActor
public final class ReminderWindowController {
	static let panelWidth: CGFloat = 380

	private static let cornerRadius: CGFloat = 12

	/// Offset applied to each successively shown panel so that simultaneous reminders
	/// stack visibly instead of overlapping exactly.
	private static let stackOffset: CGFloat = 24

	/// Called when the user ignores a reminder.
	public var onIgnore: (@MainActor (ReminderFire) -> Void)?
	/// Called when the user snoozes a reminder.
	public var onSnooze: (@MainActor (ReminderFire, SnoozeOption) -> Void)?

	private var panels: [String: ReminderPanel] = [:]

	public init() {}

	/// Shows a panel for each fire that is not already on screen.
	public func present(_ fires: [ReminderFire]) {
		for fire in fires where panels[fire.id] == nil {
			let panel = makePanel(for: fire)
			panels[fire.id] = panel
			position(panel, stackIndex: panels.count - 1)
			fadeIn(panel)
		}
	}

	// MARK: - Panel construction

	private func makePanel(for fire: ReminderFire) -> ReminderPanel {
		let content = ReminderView(
			fire: fire,
			onIgnore: { [weak self] in self?.ignore(fire) },
			onSnooze: { [weak self] option in self?.snooze(fire, by: option) }
		)

		let panel = ReminderPanel(
			contentRect: NSRect(x: 0, y: 0, width: Self.panelWidth, height: 200),
			styleMask: [.borderless, .nonactivatingPanel],
			backing: .buffered,
			defer: false
		)
		panel.isFloatingPanel = true
		// Stay above ordinary windows so a reminder is not lost behind them.
		panel.level = .floating
		panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
		panel.isOpaque = false
		panel.backgroundColor = .clear
		panel.hasShadow = true
		panel.isMovableByWindowBackground = true
		panel.hidesOnDeactivate = false
		panel.isReleasedWhenClosed = false
		panel.animationBehavior = .utilityWindow

		let hostingView = NSHostingView(rootView: content)
		hostingView.frame = NSRect(x: 0, y: 0, width: Self.panelWidth, height: 200)
		hostingView.layoutSubtreeIfNeeded()
		let height = max(hostingView.fittingSize.height, 180)

		// The material behind the content is what gives the panel its
		// Quick Look-like translucency. A `behindWindow` material is composited by
		// the window server in the *window's* shape, so its corners are rounded
		// with a mask image; `layer.cornerRadius` would only clip the content on
		// top and leave the material square behind it.
		let effectView = NSVisualEffectView(
			frame: NSRect(x: 0, y: 0, width: Self.panelWidth, height: height)
		)
		effectView.material = .hudWindow
		effectView.blendingMode = .behindWindow
		effectView.state = .active
		effectView.maskImage = Self.roundedMask(cornerRadius: Self.cornerRadius)

		hostingView.frame = effectView.bounds
		hostingView.autoresizingMask = [.width, .height]
		effectView.addSubview(hostingView)

		panel.contentView = effectView
		panel.setContentSize(NSSize(width: Self.panelWidth, height: height))

		return panel
	}

	private func position(_ panel: NSPanel, stackIndex: Int) {
		guard let screen = NSScreen.main else {
			panel.center()
			return
		}
		let visibleFrame = screen.visibleFrame
		let size = panel.frame.size
		let offset = CGFloat(stackIndex) * Self.stackOffset
		let origin = NSPoint(
			x: visibleFrame.midX - size.width / 2 + offset,
			y: visibleFrame.midY - size.height / 2 - offset
		)
		panel.setFrameOrigin(origin)
	}

	// MARK: - Helpers

	/// A resizable rounded-rectangle mask, used to round the material itself.
	private static func roundedMask(cornerRadius: CGFloat) -> NSImage {
		// The image only needs to be large enough to contain one corner; the
		// stretchable middle is defined by the cap insets.
		let edge = cornerRadius * 2 + 1
		let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
			NSColor.black.setFill()
			NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius).fill()
			return true
		}
		image.capInsets = NSEdgeInsets(
			top: cornerRadius,
			left: cornerRadius,
			bottom: cornerRadius,
			right: cornerRadius
		)
		image.resizingMode = .stretch
		return image
	}

	private func fadeIn(_ panel: NSPanel) {
		panel.alphaValue = 0
		// Shown without activating the app, so the user's current app keeps focus.
		panel.orderFrontRegardless()
		NSAnimationContext.runAnimationGroup { context in
			context.duration = 0.15
			panel.animator().alphaValue = 1
		}
	}

	// MARK: - Actions

	private func ignore(_ fire: ReminderFire) {
		close(panelFor: fire)
		onIgnore?(fire)
	}

	private func snooze(_ fire: ReminderFire, by option: SnoozeOption) {
		close(panelFor: fire)
		onSnooze?(fire, option)
	}

	private func close(panelFor fire: ReminderFire) {
		guard let panel = panels.removeValue(forKey: fire.id) else { return }
		panel.close()
	}
}

/// A panel that can take key input without activating the application, so that
/// its controls stay usable while the user's app remains frontmost.
private final class ReminderPanel: NSPanel {
	override var canBecomeKey: Bool { true }
	override var canBecomeMain: Bool { false }

	override func cancelOperation(_ sender: Any?) {
		// Escape deliberately does not dismiss a reminder: the user must pick
		// either Ignore or Snooze. Swallowing it here also avoids the beep the
		// system would otherwise emit for an unhandled Escape.
	}
}
