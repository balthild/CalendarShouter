import AppKit
import SwiftUI

/// Owns the settings window, creating it on first use.
///
/// The window is a normal titled window with an expanded toolbar. Its tabs are
/// installed as custom toolbar items rather than left to `NSTabViewController`'s
/// toolbar tab style: the system's own tab items have no padding or spacing of
/// their own and expose no way to add any, whereas custom items let the button
/// view supply both while still sitting in the real toolbar, so the material,
/// position and window chrome stay native.
@MainActor
public final class SettingsWindowController: NSObject, NSToolbarDelegate {
	/// Builds the window's content for the current selection.
	public typealias ContentBuilder = @MainActor (SettingsSelection) -> AnyView

	private let activationPolicy: ActivationPolicyController
	private let makeContent: ContentBuilder
	private let selection = SettingsSelection()

	private var window: NSWindow?
	private var isPresented = false
	nonisolated(unsafe) private var closeObserver: NSObjectProtocol?

	public init(
		activationPolicy: ActivationPolicyController,
		makeContent: @escaping ContentBuilder
	) {
		self.activationPolicy = activationPolicy
		self.makeContent = makeContent
		super.init()
	}

	deinit {
		if let closeObserver {
			NotificationCenter.default.removeObserver(closeObserver)
		}
	}

	/// Brings the settings window to the front, creating and centering it first
	/// if needed.
	public func show() {
		if window == nil {
			createWindow()
		}
		guard let window else { return }

		if !isPresented {
			isPresented = true
			// Shows the Dock icon for as long as the window is open.
			activationPolicy.windowDidOpen()
			// Sized before centring: the hosting view has not been laid out on the
			// first call, and `center()` on a wrongly sized window leaves it
			// off-centre.
			window.setContentSize(contentSize(for: selection.tab))
			window.center()
		}

		NSApp.activate(ignoringOtherApps: true)
		window.makeKeyAndOrderFront(nil)
	}

	/// The settings window, once it has been created; used to host sheets.
	public var presentedWindow: NSWindow? { window }

	// MARK: - Window

	private func createWindow() {
		// The window is created without content so that its toolbar exists before
		// any hosting view is installed.
		let window = NSWindow(
			contentRect: NSRect(origin: .zero, size: contentSize(for: selection.tab)),
			styleMask: [.titled, .closable],
			backing: .buffered,
			defer: false
		)
		window.title = String(localizable: .settingsWindowTitle)
		window.isReleasedWhenClosed = false
		// Never restore a frame from a previous run, so the window opens centred
		// rather than wherever it happened to be when the app last quit.
		window.isRestorable = false
		// Float above ordinary windows so the window is not hidden behind other
		// apps — including while a system permission prompt is on screen.
		window.level = .floating
		// A floating-level window is excluded from Mission Control by default.
		window.collectionBehavior.insert(.managed)

		let toolbar = NSToolbar()
		toolbar.delegate = self
		// The custom item views draw their own labels, so the toolbar must not
		// add one beneath them.
		toolbar.displayMode = .iconOnly
		if #available(macOS 15, *) {
			toolbar.allowsDisplayModeCustomization = false
		}

		window.toolbar = toolbar
		// The expanded style keeps the title bar at its normal height, so the
		// traffic lights stay in the title bar, the title is visible, and the tab
		// items occupy the row beneath.
		window.toolbarStyle = .expanded
		// The system separator is not used at all: macOS draws it only while the
		// window is focused, so it vanished whenever focus moved away. The separator
		// and scroll-edge shadow are drawn by `SettingsForm` instead, which keeps
		// them identical regardless of focus.
		window.titlebarSeparatorStyle = .none

		window.contentView = NSHostingView(rootView: makeContent(selection))
		window.setContentSize(contentSize(for: selection.tab))
		selection.onTabChange = { [weak self] _ in self?.resizeToFitCurrentPane() }

		closeObserver = NotificationCenter.default.addObserver(
			forName: NSWindow.willCloseNotification,
			object: window,
			queue: .main
		) { [weak self] _ in
			// Registered on the main queue.
			MainActor.assumeIsolated { self?.handleWindowWillClose() }
		}

		self.window = window
	}

	private func handleWindowWillClose() {
		guard isPresented else { return }
		isPresented = false
		activationPolicy.windowDidClose()
	}

	// MARK: - Sizing

	/// Resizes the window to the pane now shown, animated, keeping its top edge and
	/// horizontal position so the tab strip does not jump.
	private func resizeToFitCurrentPane() {
		guard let window, window.isVisible else { return }
		let fittedContentSize = contentSize(for: selection.tab)
		let fittedFrame = window.frameRect(
			forContentRect: NSRect(origin: .zero, size: fittedContentSize)
		)
		let current = window.frame
		let targetFrame = NSRect(
			x: current.minX,
			y: current.maxY - fittedFrame.height,
			width: fittedFrame.width,
			height: fittedFrame.height
		)
		guard targetFrame.size != current.size else { return }
		// Growing from a short pane to a tall one leaves the content momentarily taller than
		// the window, which makes an overlay scroller appear and then vanish again once the
		// animation finishes. The scrollers are held off until it has; the flag covers the
		// pane's own scroll view, which SwiftUI only creates part-way through the animation.
		SettingsWindowResize.isAnimating = true
		Self.setVerticalScrollersHidden(true, in: window.contentView)
		NSAnimationContext.runAnimationGroup { context in
			context.duration = 0.2
			context.allowsImplicitAnimation = true
			window.animator().setFrame(targetFrame, display: true)
		} completionHandler: {
			MainActor.assumeIsolated {
				SettingsWindowResize.isAnimating = false
				Self.setVerticalScrollersHidden(false, in: window.contentView)
			}
		}
	}

	private static func setVerticalScrollersHidden(_ hidden: Bool, in view: NSView?) {
		guard let view else { return }
		if let scrollView = view as? NSScrollView {
			scrollView.hasVerticalScroller = !hidden
		}
		for subview in view.subviews {
			setVerticalScrollersHidden(hidden, in: subview)
		}
	}

	/// The content size that fits the given pane, capped; a taller pane scrolls.
	private func contentSize(for tab: SettingsTab) -> NSSize {
		NSSize(
			width: SettingsPanes.width,
			height: min(measuredHeight(for: tab), maximumContentHeight())
		)
	}

	/// Lays the pane out off-screen, at the window's width, to find the height it wants.
	private func measuredHeight(for tab: SettingsTab) -> CGFloat {
		let probe = NSHostingView(rootView: makeContent(SettingsSelection(tab: tab)))
		probe.frame = NSRect(
			origin: .zero,
			size: NSSize(width: SettingsPanes.width, height: SettingsPanes.fallbackHeight)
		)
		probe.layoutSubtreeIfNeeded()
		let height = probe.fittingSize.height
		guard height.isFinite, height > 0 else { return SettingsPanes.fallbackHeight }
		return height.rounded(.up)
	}

	private func maximumContentHeight() -> CGFloat {
		let screen = window?.screen ?? NSScreen.main
		let usableHeight = screen?.visibleFrame.height ?? SettingsPanes.fallbackHeight
		return (usableHeight * SettingsPanes.maximumHeightFraction).rounded(.down)
	}

	// MARK: - Toolbar

	public func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
		// Flexible space either side centres the tabs, as a preferences window has
		// them.
		[.flexibleSpace]
			+ SettingsTab.allCases.map(\.toolbarItemIdentifier)
			+ [.flexibleSpace]
	}

	public func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
		[.flexibleSpace] + SettingsTab.allCases.map(\.toolbarItemIdentifier)
	}

	public func toolbar(
		_ toolbar: NSToolbar,
		itemForItemIdentifier identifier: NSToolbarItem.Identifier,
		willBeInsertedIntoToolbar flag: Bool
	) -> NSToolbarItem? {
		guard let tab = SettingsTab.from(toolbarItemIdentifier: identifier) else { return nil }

		let item = NSToolbarItem(itemIdentifier: identifier)
		item.label = String(localizable: tab.localizedLabel)
		let button = NonDraggableHostingView(
			rootView: SettingsTabButton(tab: tab, selection: selection)
		)
		button.frame = NSRect(origin: .zero, size: SettingsTabButton.size)
		item.view = button
		return item
	}
}

/// A hosting view that does not start a window drag.
///
/// The toolbar's background is draggable, and a view placed in it passes the click on
/// unless it opts out — which would turn a press-and-move on a tab into a window drag
/// instead of a button click. Opting out keeps the buttons behaving as buttons while
/// the rest of the tab bar still moves the window.
private final class NonDraggableHostingView<Content: View>: NSHostingView<Content> {
	override var mouseDownCanMoveWindow: Bool { false }

	@MainActor required init(rootView: Content) {
		super.init(rootView: rootView)
	}

	@MainActor @preconcurrency required dynamic init?(coder: NSCoder) {
		fatalError("init(coder:) is not supported")
	}
}
