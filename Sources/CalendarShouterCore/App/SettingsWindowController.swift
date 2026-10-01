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
	private var contentHostingView: ContentSizingHostingView<AnyView>?
	private var isPresented = false
	private var tabButtons: [SettingsTab: SettingsTabButton] = [:]
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
			// Laid out before being measured, so the window opens at the size of the pane it is
			// about to show rather than at the placeholder size it was created with. Centred
			// after sizing, so it is centred on the size it opens at.
			window.layoutIfNeeded()
			window.setContentSize(initialContentSize())
			window.center()
		}

		NSApp.activate(ignoringOtherApps: true)
		let wasVisible = window.isVisible
		window.makeKeyAndOrderFront(nil)
		if !wasVisible {
			clearInitialFocus(in: window)
		}
	}

	/// Leaves the window, rather than a control, as the first responder when it appears.
	///
	/// As SwiftUI installs the pane it hands first responder to the pane's first control,
	/// which draws that control's focus ring before the user has touched the keyboard. AppKit
	/// itself reserves the ring for keyboard navigation, so the ring comes back on the first
	/// Tab — this only removes the ring nothing asked for. Cleared on the next run loop turn,
	/// since SwiftUI sets the responder after `makeKeyAndOrderFront` returns.
	private func clearInitialFocus(in window: NSWindow) {
		DispatchQueue.main.async { [weak window] in
			MainActor.assumeIsolated {
				guard let window, window.isVisible else { return }
				_ = window.makeFirstResponder(nil)
			}
		}
	}

	/// The settings window, once it has been created; used to host sheets.
	public var presentedWindow: NSWindow? { window }

	// MARK: - Window

	private func createWindow() {
		// The window is created without content so that its toolbar exists before
		// any hosting view is installed.
		let window = NSWindow(
			contentRect: NSRect(origin: .zero, size: SettingsPaneMetrics.initialContentSize),
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

		let hostingView = ContentSizingHostingView(rootView: makeContent(selection))
		hostingView.onContentHeightChange = { [weak self] height in
			self?.resizeToFitContentHeight(height)
		}
		contentHostingView = hostingView
		window.contentView = hostingView
		selection.onTabChange = { [weak self] _ in
			self?.updateTabButtons()
		}

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

	/// Grows or shrinks the window to the content's height, animated, keeping the top edge and
	/// horizontal position so the tab strip does not jump.
	///
	/// Driven by the content itself rather than by a measurement taken once when the pane
	/// appears: a pane whose content arrives asynchronously — the Canvas pane's course list is
	/// the first of them — asks for more room after it is already on screen.
	private func resizeToFitContentHeight(_ contentHeight: CGFloat) {
		guard let window, window.isVisible else { return }
		// Mid-animation the content is laid out at an intermediate size, so a report taken then
		// would start a second animation from the wrong height. The animation's completion
		// re-measures once it has settled, so a change made in the meantime is not lost.
		guard !SettingsWindowResize.isAnimating else { return }

		let fittedSize = NSSize(
			width: SettingsPaneMetrics.width,
			height: min(contentHeight, maximumContentHeight())
		)
		let fittedFrame = window.frameRect(forContentRect: NSRect(origin: .zero, size: fittedSize))
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
		let token = SettingsWindowResize.begin()
		Self.setVerticalScrollersHidden(true, in: window.contentView)
		NSAnimationContext.runAnimationGroup { context in
			context.duration = 0.2
			context.allowsImplicitAnimation = true
			window.animator().setFrame(targetFrame, display: true)
		} completionHandler: { [weak self] in
			MainActor.assumeIsolated {
				// A superseded animation's completion must not re-show the scrollers while
				// the current one is still animating.
				guard SettingsWindowResize.end(token) else { return }
				Self.setVerticalScrollersHidden(false, in: window.contentView)
				self?.contentHostingView?.reportContentHeight()
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

	/// The content size the window opens at.
	///
	/// The off-screen probe this replaces measured `fittingSize`, which comes out short for a
	/// grouped form, so the pane always scrolled a little. The live hosting view can be measured
	/// instead, as soon as it has been laid out.
	private func initialContentSize() -> NSSize {
		NSSize(
			width: SettingsPaneMetrics.width,
			height: min(
				contentHostingView?.contentHeight ?? SettingsPaneMetrics.fallbackHeight,
				maximumContentHeight()
			)
		)
	}

	private func maximumContentHeight() -> CGFloat {
		let screen = window?.screen ?? NSScreen.main
		let usableHeight = screen?.visibleFrame.height ?? SettingsPaneMetrics.fallbackHeight
		return (usableHeight * SettingsPaneMetrics.maximumHeightFraction).rounded(.down)
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

		let button = SettingsTabButton(tab: tab)
		button.translatesAutoresizingMaskIntoConstraints = false
		button.setSelected(tab == selection.tab)
		button.onSelect = { [weak self] tab in self?.selection.tab = tab }
		tabButtons[tab] = button

		let container = NSView()
		container.translatesAutoresizingMaskIntoConstraints = false
		container.addSubview(button)
		NSLayoutConstraint.activate([
			container.leadingAnchor.constraint(equalTo: button.leadingAnchor),
			container.trailingAnchor.constraint(equalTo: button.trailingAnchor),
			container.topAnchor.constraint(equalTo: button.topAnchor),
			container.bottomAnchor.constraint(
				equalTo: button.bottomAnchor,
				constant: SettingsTabButton.bottomSpacing
			),
		])

		let item = NSToolbarItem(itemIdentifier: identifier)
		item.label = String(localizable: tab.localizedLabel)
		item.view = container

		return item
	}

	/// Keeps the toolbar buttons' selected appearance in step with the current pane.
	private func updateTabButtons() {
		for (tab, button) in tabButtons {
			button.setSelected(tab == selection.tab)
		}
	}
}
