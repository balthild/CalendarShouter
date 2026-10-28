import AppKit
import SwiftUI

/// Builds the borderless, translucent panels the app floats above other windows, so every
/// such panel shares the same material, shape and reveal.
@MainActor
enum TranslucentPanel {
	static let cornerRadius: CGFloat = 12

	/// Configures `panel` to show `content` on a rounded material spanning `width`.
	///
	/// The panel is sized to the content's height.
	static func configure<Content: View>(_ panel: NSPanel, content: Content, width: CGFloat) {
		panel.isFloatingPanel = true
		// Stay above ordinary windows so the panel is not lost behind them.
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
		hostingView.frame = NSRect(x: 0, y: 0, width: width, height: 200)
		hostingView.layoutSubtreeIfNeeded()
		// Sized to the content, with no minimum: a taller panel would centre the
		// content and inflate the apparent top and bottom padding.
		let height = hostingView.fittingSize.height

		// The material behind the content is what gives the panel its
		// Quick Look-like translucency. A `behindWindow` material is composited by
		// the window server in the *window's* shape, so its corners are rounded
		// with a mask image; `layer.cornerRadius` would only clip the content on
		// top and leave the material square behind it.
		let effectView = NSVisualEffectView(
			frame: NSRect(x: 0, y: 0, width: width, height: height)
		)
		effectView.material = .hudWindow
		effectView.blendingMode = .behindWindow
		effectView.state = .active
		effectView.maskImage = roundedMask(cornerRadius: cornerRadius)

		hostingView.frame = effectView.bounds
		hostingView.autoresizingMask = [.width, .height]
		effectView.addSubview(hostingView)

		panel.contentView = effectView
		panel.setContentSize(NSSize(width: width, height: height))
	}

	/// Centres `panel` on the main screen.
	static func center(_ panel: NSPanel) {
		guard let screen = NSScreen.main else {
			panel.center()
			return
		}
		let visibleFrame = screen.visibleFrame
		let size = panel.frame.size
		panel.setFrameOrigin(
			NSPoint(
				x: visibleFrame.midX - size.width / 2,
				y: visibleFrame.midY - size.height / 2
			)
		)
	}

	/// Shows `panel` without activating the app, so the user's current app keeps focus.
	static func fadeIn(_ panel: NSPanel) {
		panel.alphaValue = 0
		panel.orderFrontRegardless()
		NSAnimationContext.runAnimationGroup { context in
			context.duration = 0.15
			panel.animator().alphaValue = 1
		}
		clearInitialFocus(in: panel)
	}

	/// Leaves the panel, rather than its first control, as the first responder once it appears.
	///
	/// SwiftUI hands first responder to the content's first control as the panel is shown, which
	/// draws that control's focus ring before the user has touched the keyboard. AppKit itself
	/// reserves the ring for keyboard navigation, so the ring comes back on the first Tab — this
	/// only removes the ring nothing asked for. Cleared on the next run loop turn, since SwiftUI
	/// sets the responder after the panel is ordered front.
	private static func clearInitialFocus(in panel: NSPanel) {
		DispatchQueue.main.async { [weak panel] in
			MainActor.assumeIsolated {
				guard let panel, panel.isVisible else { return }
				_ = panel.makeFirstResponder(nil)
			}
		}
	}

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
}
