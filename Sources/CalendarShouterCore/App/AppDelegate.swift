import AppKit

/// Owns the application's top-level controllers and wires them together.
@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate {
	private let singleInstance = SingleInstanceController()
	private var coordinator: AppCoordinator?

	public override init() {
		super.init()
	}

	public func applicationWillFinishLaunching(_ notification: Notification) {
		// A bundled app is already protected by `LSMultipleInstancesProhibited`;
		// this covers launches that bypass LaunchServices (such as `swift run`).
		guard !singleInstance.acquirePrimaryInstance() else { return }
		singleInstance.requestPrimaryInstanceToShowSettings()
		// Give the running instance a moment to react before this one goes away.
		Thread.sleep(forTimeInterval: SingleInstanceController.handoffDelay)
		exit(EXIT_SUCCESS)
	}

	public func applicationDidFinishLaunching(_ notification: Notification) {
		NSApp.setActivationPolicy(.accessory)
		installMainMenu()

		let coordinator = AppCoordinator(singleInstance: singleInstance)
		self.coordinator = coordinator
		coordinator.start()

		// Development aid: shows a reminder immediately so the panel can be checked.
		if CommandLine.arguments.contains("--demo-calendar") {
			coordinator.presentDemoCalendarEvent()
		} else if CommandLine.arguments.contains("--demo-calendar-missed") {
			coordinator.presentDemoCalendarMissedEvents()
		} else if CommandLine.arguments.contains("--demo-reminder") {
			coordinator.presentDemoReminder()
		}

		if CommandLine.arguments.contains("--open-settings") {
			coordinator.showSettings()
		}
	}

	/// Installs the menu bar shown while a window is open.
	///
	/// The app has no nib, so there is no menu unless one is built here. Without
	/// it no key equivalent is routed anywhere — ⌘W in particular has no menu item
	/// to carry it, so the settings window could not be closed from the keyboard.
	private func installMainMenu() {
		let mainMenu = NSMenu()

		// Application menu. macOS always titles it with the app name.
		let appMenuItem = NSMenuItem()
		let appMenu = NSMenu()
		add(to: appMenu, title: .menuSettings, action: #selector(showSettings), key: ",")
		appMenu.addItem(.separator())
		// Quit deliberately carries no key equivalent: this is a background app,
		// so ⌘Q while the settings window happens to be open would end it by
		// accident. Quitting is instead a deliberate click, either here or in the
		// status item's menu. Targeting `NSApp` (rather than this delegate) is what
		// keeps the item enabled, since it is `NSApplication` that implements
		// `terminate:`.
		let quitItem = appMenu.addItem(
			withTitle: String(localizable: .menuQuit),
			action: #selector(NSApplication.terminate(_:)),
			keyEquivalent: ""
		)
		quitItem.target = NSApp
		appMenuItem.submenu = appMenu
		mainMenu.addItem(appMenuItem)

		// File menu, where Close belongs. The item's target is left as `nil` so it
		// travels the responder chain to whichever window is key.
		let fileMenuItem = NSMenuItem()
		let fileMenu = NSMenu(title: String(localizable: .menuFile))
		fileMenu.addItem(
			withTitle: String(localizable: .menuClose),
			action: #selector(NSWindow.performClose(_:)),
			keyEquivalent: "w"
		)
		fileMenuItem.submenu = fileMenu
		mainMenu.addItem(fileMenuItem)

		// Edit menu. Every item targets the responder chain, so the standard
		// selectors land on whatever is being edited. Without this menu ⌘V reaches
		// nothing at all, and WebKit leaves Paste out of the web view's own context
		// menu for the same reason: it validates those items against the chain.
		let editMenuItem = NSMenuItem()
		let editMenu = NSMenu(title: String(localizable: .menuEdit))
		let editItems: [(title: String.Localizable, action: Selector, key: String)] = [
			(.menuUndo, Selector(("undo:")), "z"),
			(.menuRedo, Selector(("redo:")), "Z"),
			(.menuCut, #selector(NSText.cut(_:)), "x"),
			(.menuCopy, #selector(NSText.copy(_:)), "c"),
			(.menuPaste, #selector(NSText.paste(_:)), "v"),
			(.menuSelectAll, #selector(NSText.selectAll(_:)), "a"),
		]
		for (index, item) in editItems.enumerated() {
			if index == 2 { editMenu.addItem(.separator()) }
			editMenu.addItem(
				withTitle: String(localizable: item.title),
				action: item.action,
				keyEquivalent: item.key
			)
		}
		editMenuItem.submenu = editMenu
		mainMenu.addItem(editMenuItem)

		NSApp.mainMenu = mainMenu
	}

	/// Adds a localized item targeting this delegate.
	private func add(to menu: NSMenu, title: String.Localizable, action: Selector, key: String) {
		let item = menu.addItem(
			withTitle: String(localizable: title),
			action: action,
			keyEquivalent: key
		)
		item.target = self
	}

	@objc private func showSettings() {
		coordinator?.showSettings()
	}

	public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
		false
	}

	/// Opening the app again (from Finder, the Dock or `open`) shows settings.
	public func applicationShouldHandleReopen(
		_ sender: NSApplication,
		hasVisibleWindows flag: Bool
	) -> Bool {
		coordinator?.showSettings()
		return true
	}
}
