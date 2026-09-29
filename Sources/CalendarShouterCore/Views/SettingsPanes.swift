import AppKit
import SwiftUI

/// The settings window's tabs.
public enum SettingsTab: String, CaseIterable, Identifiable {
	case general
	case calendars
	case sound

	public var id: String { rawValue }

	var localizedLabel: String.Localizable {
		switch self {
		case .general: .tabGeneral
		case .calendars: .tabCalendars
		case .sound: .tabSound
		}
	}

	var symbolName: String {
		switch self {
		case .general: "gearshape"
		case .calendars: "calendar"
		case .sound: "speaker.wave.2"
		}
	}

	var toolbarItemIdentifier: NSToolbarItem.Identifier {
		NSToolbarItem.Identifier("tab.\(rawValue)")
	}

	static func from(toolbarItemIdentifier identifier: NSToolbarItem.Identifier) -> SettingsTab? {
		allCases.first { $0.toolbarItemIdentifier == identifier }
	}
}

/// Which tab the settings window is showing.
@MainActor
@Observable
public final class SettingsSelection {
	public var tab: SettingsTab {
		didSet {
			guard tab != oldValue else { return }
			onTabChange?(tab)
		}
	}

	/// Called after the tab changes so the window can resize to the new pane.
	@ObservationIgnored public var onTabChange: ((SettingsTab) -> Void)?

	public init(tab: SettingsTab = .general) {
		self.tab = tab
	}
}

/// The metrics shared by every pane.
enum SettingsPanes {
	static let width: CGFloat = 400

	static let fallbackHeight: CGFloat = 360

	/// The tallest the window may grow, as a fraction of the screen's usable height.
	static let maximumHeightFraction: CGFloat = 0.6
}

/// Whether the settings window is animating to a new pane's height.
///
/// A short pane switching to a tall one leaves the content momentarily taller than the
/// window, which would show an overlay scroller that vanishes again when the animation
/// ends. Panes read this when they appear, so a pane created mid-animation keeps its
/// scroller off until the window has settled.
///
/// A quick switch back restarts the animation while the previous one is still in flight.
/// Both completions then run, and the earlier one would clear the flag — and re-show the
/// scrollers — while the later animation is still growing the window, flashing the
/// scroller. Callers therefore pair `begin()` with `end(_:)` so only the latest
/// animation's completion clears the flag.
@MainActor
enum SettingsWindowResize {
	private(set) static var isAnimating = false

	/// Bumped for each resize so a superseded animation's completion can be ignored.
	private static var generation = 0

	/// Marks a resize as started and returns the token its completion passes to `end(_:)`.
	static func begin() -> Int {
		generation += 1
		isAnimating = true
		return generation
	}

	/// Clears the flag if `token` is still the latest resize; returns whether it did.
	@discardableResult
	static func end(_ token: Int) -> Bool {
		guard token == generation else { return false }
		isAnimating = false
		return true
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

	/// Used to draw the separator one *physical* pixel tall, rather than one point (which
	/// is two pixels on a Retina display).
	@Environment(\.displayScale) private var displayScale

	@State private var isScrolled = false

	var body: some View {
		Form {
			content
				.background { ScrollEdgeObserver(isScrolled: $isScrolled) }
		}
		.formStyle(.grouped)
		.overlay(alignment: .top) {
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
		.animation(.easeInOut(duration: 0.15), value: isScrolled)
		.frame(maxWidth: .infinity)
	}
}

// MARK: - Tab button

/// One tab, drawn as a toolbar item.
///
/// The toolbar supplies the gaps between items itself, so none is added horizontally
/// here; the vertical padding is this view's own, since the toolbar gives none.
struct SettingsTabButton: View {
	/// The button's content, excluding its vertical padding.
	private static let contentSize = CGSize(width: 64, height: 48)
	private static let bottomPadding: CGFloat = 2

	/// Total size, handed to the hosting view for the toolbar item.
	static let size = CGSize(
		width: contentSize.width,
		height: contentSize.height + bottomPadding
	)

	let tab: SettingsTab
	@Bindable var selection: SettingsSelection

	@State private var isHovering = false

	var body: some View {
		Button {
			selection.tab = tab
		} label: {
			VStack(spacing: 2) {
				Image(systemName: tab.symbolName)
					.font(.system(size: 17))
				Text(localizable: tab.localizedLabel)
					.font(.system(size: 11))
			}
			.frame(width: Self.contentSize.width, height: Self.contentSize.height)
			.contentShape(Rectangle())
		}
		.buttonStyle(SettingsTabButtonStyle(isSelected: selection.tab == tab, isHovering: isHovering))
		// Without this the window's initial first responder draws a focus ring.
		.focusEffectDisabled()
		.onHover { isHovering = $0 }
		.padding(.bottom, Self.bottomPadding)
		.frame(width: Self.size.width, height: Self.size.height)
		.accessibilityAddTraits(selection.tab == tab ? [.isSelected] : [])
	}
}

private struct SettingsTabButtonStyle: ButtonStyle {
	let isSelected: Bool
	let isHovering: Bool

	func makeBody(configuration: Configuration) -> some View {
		configuration.label
			.foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
			.background {
				RoundedRectangle(cornerRadius: 7, style: .continuous)
					.fill(background(isPressed: configuration.isPressed))
			}
	}

	private func background(isPressed: Bool) -> Color {
		if isPressed {
			return Color.primary.opacity(0.14)
		}
		if isSelected || isHovering {
			return Color.primary.opacity(0.07)
		}
		return .clear
	}
}

// MARK: - Content

/// Hosts the pane for the selected tab.
struct SettingsContent: View {
	@Bindable var selection: SettingsSelection
	@Bindable var store: SettingsStore
	@Bindable var loginItemController: LoginItemController
	let calendarService: EventKitCalendarService
	let soundCatalog: SoundCatalog
	let onRequestCalendarAccess: @MainActor () -> Void
	let onOpenCalendarPrivacySettings: @MainActor () -> Void
	let onRemindersAccessNeeded: @MainActor () -> Void
	let onPreviewSound: @MainActor (String) -> Void

	var body: some View {
		switch selection.tab {
		case .general:
			GeneralSettingsPane(
				store: store,
				loginItemController: loginItemController,
				onRemindersAccessNeeded: onRemindersAccessNeeded
			)
		case .calendars:
			CalendarsSettingsPane(
				store: store,
				calendarService: calendarService,
				onRequestAccess: onRequestCalendarAccess,
				onOpenPrivacySettings: onOpenCalendarPrivacySettings
			)
		case .sound:
			SoundSettingsPane(
				store: store,
				soundCatalog: soundCatalog,
				onPreviewSound: onPreviewSound
			)
		}
	}
}

// MARK: - General

struct GeneralSettingsPane: View {
	@Bindable var store: SettingsStore
	@Bindable var loginItemController: LoginItemController
	let onRemindersAccessNeeded: @MainActor () -> Void

	var body: some View {
		SettingsForm {
			Section {
				Toggle(isOn: $store.showMenuBarIcon) {
					Text(localizable: .showMenuBarIcon)
				}
				Toggle(isOn: launchAtLoginBinding) {
					Text(localizable: .launchAtLogin)
				}
				.disabled(!loginItemController.isSupported)

				Toggle(isOn: $store.showMissedReminders) {
					Text(localizable: .showMissedReminders)
				}
				Toggle(isOn: remindersBinding) {
					Text(localizable: .includeReminders)
				}
			}
		}
	}

	/// Turning reminders on asks the coordinator to make sure access is granted; it decides
	/// whether that means prompting or explaining a previous refusal.
	private var remindersBinding: Binding<Bool> {
		Binding(
			get: { store.includeReminders },
			set: { isOn in
				store.includeReminders = isOn
				if isOn { onRemindersAccessNeeded() }
			}
		)
	}

	/// `LoginItemController` owns the truth, so the toggle reads back from it.
	private var launchAtLoginBinding: Binding<Bool> {
		Binding(
			get: { loginItemController.isEnabled },
			set: { loginItemController.setEnabled($0) }
		)
	}
}

// MARK: - Calendars

struct CalendarsSettingsPane: View {
	@Bindable var store: SettingsStore
	let calendarService: EventKitCalendarService
	let onRequestAccess: @MainActor () -> Void
	let onOpenPrivacySettings: @MainActor () -> Void

	var body: some View {
		Group {
			if calendarService.authorization.canReadEvents {
				calendarList
			} else {
				accessPrompt
			}
		}
		.frame(maxWidth: .infinity)
	}

	private var calendarList: some View {
		SettingsForm {
			if calendarService.accounts.isEmpty {
				Section {
					Text(localizable: .noCalendars)
						.foregroundStyle(.secondary)
				}
			} else {
				ForEach(Array(calendarService.accounts.enumerated()), id: \.element.id) {
					index,
					account in
					Section {
						VStack(alignment: .leading, spacing: 10) {
							Text(account.title)
								.font(.subheadline)
								.foregroundStyle(.secondary)
								.fontWeight(.medium)

							ForEach(account.calendars) { calendar in
								Toggle(isOn: binding(for: calendar)) {
									Text(calendar.title)
										.foregroundStyle(Color.primary.opacity(0.85))
								}
								.toggleStyle(CalendarCheckboxToggleStyle(tint: Color(rgb: calendar.color)))
							}
						}
						.frame(maxWidth: .infinity, alignment: .leading)
					} header: {
						if index == 0 {
							listHeader
						}
					}
				}
			}
		}
	}

	private var listHeader: some View {
		VStack(alignment: .leading, spacing: 4) {
			Text(localizable: .enableCalendars)
				.font(.headline)
				// Section headers would otherwise be upper-cased.
				.textCase(nil)
			Text(localizable: .remindersOnlyForEnabledCalendars)
				.font(.subheadline)
				.foregroundStyle(.secondary)
				.textCase(nil)
		}
	}

	private var accessPrompt: some View {
		VStack(spacing: 12) {
			Text(localizable: .calendarAccessRequired)
				.multilineTextAlignment(.center)

			if calendarService.authorization == .denied
				|| calendarService.authorization == .restricted
			{
				Text(localizable: .calendarAccessDenied)
					.font(.footnote)
					.foregroundStyle(.secondary)
					.multilineTextAlignment(.center)
				Button(action: onOpenPrivacySettings) {
					Text(localizable: .openSystemSettings)
				}
			} else {
				Button(action: onRequestAccess) {
					Text(localizable: .grantAccess)
				}
			}
		}
		.frame(maxWidth: .infinity)
		.padding(32)
	}

	private func binding(for calendar: CalendarInfo) -> Binding<Bool> {
		Binding(
			get: { store.isReminderEnabled(forCalendarID: calendar.id) },
			set: { store.setReminderEnabled($0, forCalendarID: calendar.id) }
		)
	}
}

/// A checkbox that takes a colour of its own.
///
/// The system checkbox style ignores `.tint` and always uses the accent colour, so the box
/// is drawn here. The label and the click target are unchanged from a checkbox.
private struct CalendarCheckboxToggleStyle: ToggleStyle {
	let tint: Color

	private var edgeColor: Color { Color.black.opacity(0.25) }

	func makeBody(configuration: Configuration) -> some View {
		Button {
			configuration.isOn.toggle()
		} label: {
			HStack(spacing: 6) {
				box(isOn: configuration.isOn)
				configuration.label
			}
			.contentShape(Rectangle())
		}
		.buttonStyle(.plain)
		.focusEffectDisabled()
		.accessibilityAddTraits(configuration.isOn ? [.isSelected] : [])
	}

	private func box(isOn: Bool) -> some View {
		RoundedRectangle(cornerRadius: 3, style: .continuous)
			.fill(tint)
			.overlay {
				if isOn { tick }
			}
			.overlay {
				RoundedRectangle(cornerRadius: 3, style: .continuous)
					.strokeBorder(edgeColor, lineWidth: 1)
			}
			.frame(width: boxSize, height: boxSize)
			.opacity(isOn ? 1 : 0.5)
	}

	/// The tick, stroked twice: a thick edge stroke with a thinner white stroke over it, which
	/// leaves an edge of even thickness on every side. (Stamping the glyph at offsets instead
	/// accumulates alpha where the stamps overlap, darkening the edge unevenly.)
	private var tick: some View {
		TickShape()
			.stroke(edgeColor, style: tickStroke(tickLineWidth + 2 * tickBorderWidth))
			.overlay {
				TickShape()
					.stroke(.white, style: tickStroke(tickLineWidth))
			}
			.padding(tickInset)
	}

	private func tickStroke(_ lineWidth: CGFloat) -> StrokeStyle {
		StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round)
	}

	/// Widths of the tick's two strokes
	private var tickLineWidth: CGFloat { 1.36 }
	private var tickBorderWidth: CGFloat { 1 }

	/// The inset of the tick from the box's edge.
	private var tickInset: CGFloat { 3 }

	private var boxSize: CGFloat { 16 }
}

/// The tick's centreline, in fractions of its box so the proportions can be adjusted by hand.
private struct TickShape: Shape {
	private static let start = CGPoint(x: 0.12, y: 0.58)
	private static let corner = CGPoint(x: 0.38, y: 0.88)
	private static let end = CGPoint(x: 0.9, y: 0.14)

	func path(in rect: CGRect) -> Path {
		var path = Path()
		path.move(to: point(in: rect, Self.start))
		path.addLine(to: point(in: rect, Self.corner))
		path.addLine(to: point(in: rect, Self.end))
		return path
	}

	private func point(in rect: CGRect, _ fraction: CGPoint) -> CGPoint {
		return CGPoint(
			x: rect.minX + rect.width * fraction.x,
			y: rect.minY + rect.height * fraction.y
		)
	}
}

// MARK: - Sound

struct SoundSettingsPane: View {
	@Bindable var store: SettingsStore
	let soundCatalog: SoundCatalog
	let onPreviewSound: @MainActor (String) -> Void

	var body: some View {
		SettingsForm {
			Section {
				Picker(selection: $store.soundName) {
					ForEach(soundCatalog.choices) { choice in
						soundChoiceLabel(choice).tag(choice.soundName)
					}
				} label: {
					Text(localizable: .reminderSound)
				}
				.pickerStyle(.menu)
			}
		}
		// Changing the selection plays it, so the choice is immediately audible.
		.onChange(of: store.soundName) { _, newValue in
			onPreviewSound(newValue)
		}
	}

	@ViewBuilder
	private func soundChoiceLabel(_ choice: SoundChoice) -> some View {
		switch choice {
		case .none:
			Text(localizable: .noSound)
		case .system(let name):
			Text(name)
		}
	}
}
