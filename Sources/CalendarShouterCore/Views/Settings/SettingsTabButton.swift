import AppKit

/// One tab, drawn as a toolbar item.
///
/// The toolbar supplies the gaps between items itself, so none is added horizontally
/// here; the bottom spacing is added by the view the toolbar item wraps around this button.
///
/// AppKit rather than SwiftUI: a SwiftUI button inside a toolbar item is fronted by a private
/// `SwiftUI.KeyViewProxy`, whose focus the SwiftUI engine owns. Because every tab button reads
/// the selection, changing panes redraws them all, which clears that focus — and the toolbar
/// views are never linked into the content's key view loop, so Tab from the tab bar came to a
/// dead end. A plain `NSButton` holds first responder itself, survives the pane change, and
/// takes its place in the window's key view loop.
final class SettingsTabButton: NSButton {
	static let iconPointSize: CGFloat = 17
	static let labelFontSize: CGFloat = 11
	static let contentSpacing: CGFloat = 2

	static let cornerRadius: CGFloat = 7
	static let layoutSize = CGSize(width: 64, height: 48)
	static let layoutRect = NSRect(origin: .zero, size: layoutSize)

	let tab: SettingsTab

	/// Called when the button is activated.
	var onSelect: ((SettingsTab) -> Void)?

	private var isSelected = false
	private var isHovering = false
	private var hoverTrackingArea: NSTrackingArea?

	init(tab: SettingsTab) {
		self.tab = tab

		super.init(frame: Self.layoutRect)
		isBordered = false

		setButtonType(.momentaryChange)
		setAccessibilityLabel(String(localizable: tab.localizedLabel))

		target = self
		action = #selector(activate)

		// The tabs are one mutually exclusive choice, which AppKit represents as radio buttons —
		// the same way `NSTabView`'s own tabs are exposed. `NSButton` answers accessibility
		// queries through its cell (a view override is ignored), so role and value go there.
		cell?.setAccessibilityRole(.radioButton)
		cell?.setAccessibilityValue(0)

		// The button draws its own pressed state; the cell's highlight would otherwise be drawn
		// over the icon and label, washing them out instead of darkening the background.
		(cell as? NSButtonCell)?.highlightsBy = []
	}

	@available(*, unavailable)
	required init?(coder: NSCoder) {
		fatalError("init(coder:) is not supported")
	}

	/// Updates the selected appearance, which the controller drives from the window's state.
	func setSelected(_ selected: Bool) {
		guard isSelected != selected else { return }

		isSelected = selected
		needsDisplay = true

		// The state lives in the cell's accessibility value, as it does for AppKit's own radio
		// buttons, so VoiceOver has to be told it changed.
		cell?.setAccessibilityValue(selected ? 1 : 0)
		NSAccessibility.post(element: self, notification: .valueChanged)
	}

	@objc private func activate() {
		onSelect?(tab)
	}

	// The toolbar's background is draggable; a button that let the click through would turn a
	// press-and-move on a tab into a window drag.
	override var mouseDownCanMoveWindow: Bool { false }

	// The button draws its own background, so it has no title or image for AppKit to measure;
	// without this the toolbar sizes each item to nothing and the tabs pile up in the middle.
	override var intrinsicContentSize: NSSize { Self.layoutSize }

	// A borderless button refuses first responder unless Full Keyboard Access is on, which would
	// take the tabs out of the key view loop for most users.
	override var acceptsFirstResponder: Bool { true }

	// Drawing is easier to reason about top-down: the icon is centred from the top edge.
	override var isFlipped: Bool { true }

	/// AppKit changes this while the button is pressed; the content colour follows it.
	override var isHighlighted: Bool {
		didSet { needsDisplay = true }
	}

	// MARK: - Drawing

	override func draw(_ dirtyRect: NSRect) {
		drawBackground()
		drawContent()
	}

	private var foregroundColor: NSColor {
		if isSelected {
			return .controlAccentColor
		}
		if isHighlighted {
			return .secondaryLabelColor.blended(withFraction: 0.25, of: .labelColor)
				?? .secondaryLabelColor
		}
		return .secondaryLabelColor
	}

	private var backgroundColor: NSColor? {
		if isHighlighted {
			return NSColor.labelColor.withAlphaComponent(0.14)
		}
		if isSelected || isHovering {
			return NSColor.labelColor.withAlphaComponent(0.07)
		}
		return nil
	}

	private func drawBackground() {
		guard let color = backgroundColor else { return }
		color.setFill()
		NSBezierPath(
			roundedRect: bounds,
			xRadius: Self.cornerRadius,
			yRadius: Self.cornerRadius
		).fill()
	}

	/// The icon and label, stacked and centred in the content area.
	private func drawContent() {
		let icon = symbolImage()
		let iconSize = icon.size

		let text = labelText()
		let textSize = text.size()

		let contentHeight = iconSize.height + textSize.height + Self.contentSpacing

		let iconRect = NSRect(
			x: bounds.midX - iconSize.width / 2,
			y: bounds.midY - contentHeight / 2,
			width: iconSize.width,
			height: iconSize.height
		)

		let textOrigin = NSPoint(
			x: bounds.midX - textSize.width / 2,
			y: iconRect.maxY + Self.contentSpacing,
		)

		icon.draw(in: iconRect)
		text.draw(at: textOrigin)
	}

	private func labelText() -> NSAttributedString {
		let label = String(localizable: tab.localizedLabel)
		let attributes: [NSAttributedString.Key: Any] = [
			.font: NSFont.systemFont(ofSize: Self.labelFontSize),
			.foregroundColor: foregroundColor,
		]
		return NSAttributedString(string: label, attributes: attributes)
	}

	private func symbolImage() -> NSImage {
		let configuration = NSImage.SymbolConfiguration(
			pointSize: Self.iconPointSize,
			weight: .regular
		)
		.applying(NSImage.SymbolConfiguration(paletteColors: [foregroundColor]))

		let image = NSImage(systemSymbolName: tab.symbolName, accessibilityDescription: nil)?
			.withSymbolConfiguration(configuration)
		image?.isTemplate = false

		return image ?? NSImage(size: .zero)
	}

	// MARK: - Focus ring

	override var focusRingMaskBounds: NSRect { bounds }

	override func drawFocusRingMask() {
		NSBezierPath(
			roundedRect: bounds,
			xRadius: Self.cornerRadius,
			yRadius: Self.cornerRadius
		).fill()
	}

	// MARK: - Hover

	override func updateTrackingAreas() {
		super.updateTrackingAreas()
		if let hoverTrackingArea {
			removeTrackingArea(hoverTrackingArea)
		}
		let area = NSTrackingArea(
			rect: .zero,
			options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
			owner: self,
			userInfo: nil
		)
		addTrackingArea(area)
		hoverTrackingArea = area
	}

	override func mouseEntered(with event: NSEvent) {
		isHovering = true
		needsDisplay = true
	}

	override func mouseExited(with event: NSEvent) {
		isHovering = false
		needsDisplay = true
	}
}
