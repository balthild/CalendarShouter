import AppKit
import SwiftUI

/// A settings pane: a grouped form with a separator and a shadow along its top edge.
///
/// Drawn here rather than left to the window because macOS hides its own separator
/// whenever the window is not focused.
///
/// The line is permanent, unlike a system settings window: the pane's own top inset is not
/// reachable from SwiftUI, and without the line that inset reads as an unexplained gap.
/// The shadow still appears only on scrolling.
struct SettingsForm<Content: View>: View {
	@ViewBuilder var content: Content

	@State private var isScrolled = false

	var body: some View {
		Form {
			content
				.background { ScrollEdgeObserver(isScrolled: $isScrolled) }
		}
		.formStyle(.grouped)
		.modifier(SettingsTopEdge(isScrolled: isScrolled))
		.animation(.easeInOut(duration: 0.15), value: isScrolled)
		.frame(maxWidth: .infinity)
	}
}

/// The separator and scroll-edge shadow drawn along a pane's top edge.
private struct SettingsTopEdge: ViewModifier {
	let isScrolled: Bool

	/// Used to draw the separator one *physical* pixel tall, rather than one point (which
	/// is two pixels on a Retina display).
	@Environment(\.displayScale) private var displayScale

	func body(content: Content) -> some View {
		content.overlay(alignment: .top) {
			VStack(spacing: 0) {
				Rectangle()
					.fill(Color.primary.opacity(0.18))
					.frame(height: 1 / displayScale)

				if isScrolled {
					// Matches the height of the shadow a system settings window draws under
					// its toolbar; the opacity is what tunes its weight.
					LinearGradient(
						colors: [Color.black.opacity(0.1), .clear],
						startPoint: .top,
						endPoint: .bottom
					)
					.frame(height: 1.8)
				}
			}
			.allowsHitTesting(false)
		}
	}
}

// MARK: - Scroll edge

/// Watches the pane's scroll view for scrolling, and applies the scroll-view settings
/// that SwiftUI exposes no modifier for.
///
/// The position comes from the scroll view's clip view rather than from a `GeometryReader`
/// in the content: the content only moves once it reaches the very top edge, whereas the
/// clip view moves with the first point of scrolling — the instant the toolbar takes on
/// its scrolled material. Attached as the content's background purely to land inside the
/// scroll view and be able to find it.
private struct ScrollEdgeObserver: NSViewRepresentable {
	@Binding var isScrolled: Bool

	final class Coordinator {
		var binding: Binding<Bool>

		init(binding: Binding<Bool>) {
			self.binding = binding
		}

		func apply(_ scrolled: Bool) {
			guard binding.wrappedValue != scrolled else { return }
			binding.wrappedValue = scrolled
		}
	}

	/// A zero-sized view whose only job is to locate the scroll view that contains it.
	final class ObserverView: NSView {
		var onScroll: ((Bool) -> Void)?

		nonisolated(unsafe) private var observers: [NSObjectProtocol] = []
		nonisolated(unsafe) private weak var observedClipView: NSClipView?
		private var isPublishScheduled = false

		override func viewDidMoveToSuperview() {
			super.viewDidMoveToSuperview()
			attach()
		}

		override func viewDidMoveToWindow() {
			super.viewDidMoveToWindow()
			attach()
		}

		func refresh() {
			attach()
			updateScrollerVisibility()
			publish()
		}

		private func attach() {
			guard observedClipView == nil else { return }
			guard
				let scrollView = enclosingScrollView ?? Self.firstScrollView(in: window?.contentView)
			else {
				return
			}
			let clipView = scrollView.contentView
			observedClipView = clipView
			clipView.postsBoundsChangedNotifications = true
			observers.append(
				NotificationCenter.default.addObserver(
					forName: NSView.boundsDidChangeNotification,
					object: clipView,
					queue: .main
				) { [weak self] _ in
					MainActor.assumeIsolated { self?.publish() }
				}
			)
			updateScrollerVisibility()
			publish()
		}

		private func updateScrollerVisibility() {
			guard let scrollView = observedClipView?.enclosingScrollView else { return }
			let isEnabled = !SettingsWindowResize.isAnimating
			guard scrollView.hasVerticalScroller != isEnabled else { return }
			scrollView.hasVerticalScroller = isEnabled
		}

		/// Folds the flood of bounds notifications into one update per run loop turn: a
		/// window resize posts bounds AppKit has already corrected by the time the turn
		/// ends, which would otherwise read as a scroll.
		private func publish() {
			guard !isPublishScheduled else { return }
			isPublishScheduled = true
			DispatchQueue.main.async { [weak self] in
				MainActor.assumeIsolated {
					guard let self else { return }
					self.isPublishScheduled = false
					self.publishNow()
				}
			}
		}

		private func publishNow() {
			guard let clipView = observedClipView, let scrollView = clipView.enclosingScrollView else {
				return
			}
			// The clip view rests at the negative of the scroll view's top content inset,
			// but never above zero.
			let restingOrigin = min(0, -scrollView.contentInsets.top)
			onScroll?(clipView.bounds.origin.y > restingOrigin + 0.5)
		}

		private static func firstScrollView(in view: NSView?) -> NSScrollView? {
			guard let view else { return nil }
			if let scrollView = view as? NSScrollView { return scrollView }
			for subview in view.subviews {
				if let found = firstScrollView(in: subview) { return found }
			}
			return nil
		}

		deinit {
			for observer in observers {
				NotificationCenter.default.removeObserver(observer)
			}
		}
	}

	func makeCoordinator() -> Coordinator {
		Coordinator(binding: $isScrolled)
	}

	func makeNSView(context: Context) -> ObserverView {
		let observerView = ObserverView()
		let coordinator = context.coordinator
		observerView.onScroll = { coordinator.apply($0) }
		return observerView
	}

	func updateNSView(_ observerView: ObserverView, context: Context) {
		context.coordinator.binding = $isScrolled
		observerView.refresh()
	}
}
