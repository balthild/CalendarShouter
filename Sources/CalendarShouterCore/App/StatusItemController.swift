import AppKit

/// Owns the menu bar status item and its menu.
@MainActor
public final class StatusItemController: NSObject {
	private var statusItem: NSStatusItem?
	private let showSettings: @MainActor @Sendable () -> Void
	private let quit: @MainActor @Sendable () -> Void

	public init(
		showSettings: @escaping @MainActor @Sendable () -> Void,
		quit: @escaping @MainActor @Sendable () -> Void
	) {
		self.showSettings = showSettings
		self.quit = quit
		super.init()
	}

	public func setVisible(_ visible: Bool) {
		if visible {
			installStatusItem()
		} else {
			removeStatusItem()
		}
	}

	// MARK: - Status item lifecycle

	private func installStatusItem() {
		guard statusItem == nil else { return }

		// `variableLength` rather than `squareLength`: a square item is as wide as the menu
		// bar is tall, so its highlight is wider than the glyph. A variable item is sized to
		// its content, which keeps the highlight hugging the icon.
		let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
		if let button = item.button {
			let image = Self.makeStatusImage()
			image?.isTemplate = true
			image?.size = NSSize(width: Self.imageSide, height: Self.imageSide)
			button.image = image
			button.toolTip = Self.applicationName
			button.setAccessibilityLabel(Self.applicationName)
		}
		item.menu = makeMenu()
		statusItem = item
	}

	private func removeStatusItem() {
		guard let statusItem else { return }
		NSStatusBar.system.removeStatusItem(statusItem)
		self.statusItem = nil
	}

	private func makeMenu() -> NSMenu {
		let menu = NSMenu()

		let settingsItem = NSMenuItem(
			title: String(localizable: .menuSettings),
			action: #selector(handleShowSettings),
			keyEquivalent: ","
		)
		settingsItem.target = self
		menu.addItem(settingsItem)

		menu.addItem(.separator())

		let quitItem = NSMenuItem(
			title: String(localizable: .menuQuit),
			action: #selector(handleQuit),
			keyEquivalent: "q"
		)
		quitItem.target = self
		menu.addItem(quitItem)

		return menu
	}

	@objc private func handleShowSettings() {
		showSettings()
	}

	@objc private func handleQuit() {
		quit()
	}

	// MARK: - Helpers

	/// The rendered size of the menu bar glyph, square.
	private static let imageSide: CGFloat = 18

	/// The menu bar glyph, falling back to simpler symbols if a name is missing.
	private static func makeStatusImage() -> NSImage? {
		for symbolName in ["calendar.badge.clock", "bell.badge", "calendar"] {
			if let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) {
				return image
			}
		}
		return nil
	}

	/// The localized application name, used for the status item's tooltip.
	private static var applicationName: String {
		(Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
			?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String)
			?? ProcessInfo.processInfo.processName
	}
}
