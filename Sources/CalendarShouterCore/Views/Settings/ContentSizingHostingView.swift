import AppKit
import SwiftUI

/// An `NSHostingView` that tells its owner how tall its content wants to be.
///
/// A hosting view's own height is whatever the window gives it, so the window has to be told
/// separately when the content's ideal height changes — which it does on its own for a pane
/// whose data arrives asynchronously.
final class ContentSizingHostingView<Content: View>: NSHostingView<Content> {
	var onContentHeightChange: ((CGFloat) -> Void)?

	private var isReportScheduled = false

	override func layout() {
		super.layout()
		scheduleReport()
	}

	/// Reports the content's ideal height, and re-arms so the next layout can report again.
	func reportContentHeight() {
		isReportScheduled = false
		let height = contentHeight.rounded(.up)
		guard height.isFinite, height > 0 else { return }
		onContentHeightChange?(height)
	}

	/// The height the content needs.
	///
	/// Taken from the scroll view's document view, not from `fittingSize`: the latter comes out
	/// about 30 points short for a grouped form, which leaves the window always a little shorter
	/// than its content — and so scrolling — however short the pane is.
	var contentHeight: CGFloat {
		if let document = Self.firstScrollView(in: self)?.documentView, document.frame.height > 0 {
			return document.frame.height
		}
		return fittingSize.height
	}

	private static func firstScrollView(in view: NSView?) -> NSScrollView? {
		guard let view else { return nil }
		if let scrollView = view as? NSScrollView { return scrollView }
		for subview in view.subviews {
			if let found = firstScrollView(in: subview) { return found }
		}
		return nil
	}

	/// Defers the report to the next run loop turn, and folds a burst of layouts into one.
	///
	/// Reporting from inside `layout()` would resize the window before that layout had
	/// returned, so the content would be laid out again from a half-updated frame.
	private func scheduleReport() {
		guard !isReportScheduled else { return }
		isReportScheduled = true
		DispatchQueue.main.async { [weak self] in
			MainActor.assumeIsolated { self?.reportContentHeight() }
		}
	}
}
