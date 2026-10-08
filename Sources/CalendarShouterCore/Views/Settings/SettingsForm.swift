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
					scrollShadow(initial: 0.125, retention: 0.6)
				}
			}
			.allowsHitTesting(false)
		}
	}

	/// The scroll-edge shadow: `initial` opacity, each physical pixel retaining `retention` of the
	/// previous — one segment per pixel, so its height in pixels (and points) follows from
	/// `retention` as well.
	private func scrollShadow(initial: Double, retention: Double) -> some View {
		let steps = scrollShadowSteps(initial: initial, retention: retention)

		return LinearGradient(
			stops: (0...steps).map { step in
				.init(
					color: .primary.opacity(initial * pow(retention, Double(step))),
					location: Double(step) / Double(steps)
				)
			},
			startPoint: .top,
			endPoint: .bottom
		)
		.frame(height: Double(steps) / displayScale)
	}

	/// The fewest steps whose last segment still shifts the opacity by one 8-bit level; a further
	/// step could only be drawn as the background colour, so it is dropped.
	private func scrollShadowSteps(initial: Double, retention: Double) -> Int {
		let visible = 1 / 255.0
		let first = initial * (1 - retention)
		guard first > visible else { return 1 }
		return Int(ceil(log(visible / first) / log(retention))) + 1
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
		private var isRestoringTop = false

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
					MainActor.assumeIsolated {
						self?.restoreTopForNewPane()
						self?.publish()
					}
				}
			)
			updateScrollerVisibility()
			publish()
		}

		/// Puts a pane that has just been created back at its top edge.
		///
		/// While such a pane is briefly taller than the window, AppKit scrolls it on its own: the
		/// form's layout compensates for the overflow, and a `Table` inside it then asks to be
		/// scrolled into sight. Neither scroll belongs to the user — the pane has never been scrolled
		/// — and either would be drawn as the pane opening part-way down.
		///
		/// Corrected here, in the bounds notification, rather than in the deferred `publish()`: a
		/// layout pass can run during the window's display, and a block enqueued then is drained a
		/// run loop iteration later — after the frame with the offset has already been committed.
		/// The correction lands inside the same layout pass instead, before the pane is drawn.
		private func restoreTopForNewPane() {
			guard !isRestoringTop, SettingsWindowResize.isSettlingNewPane else { return }
			guard let clipView = observedClipView, let scrollView = clipView.enclosingScrollView else {
				return
			}
			let restingOrigin = min(0, -scrollView.contentInsets.top)
			guard clipView.bounds.origin.y > restingOrigin + 0.5 else { return }
			isRestoringTop = true
			clipView.scroll(to: NSPoint(x: clipView.bounds.origin.x, y: restingOrigin))
			scrollView.reflectScrolledClipView(clipView)
			isRestoringTop = false
		}

		private func updateScrollerVisibility() {
			guard let scrollView = observedClipView?.enclosingScrollView else { return }
			let isEnabled = !SettingsWindowResize.suppressesScrollers
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
