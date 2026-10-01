import AppKit

/// The settings window's tabs.
public enum SettingsTab: String, CaseIterable, Identifiable {
	case general
	case calendars
	case canvas
	case about

	public var id: String { rawValue }

	var localizedLabel: String.Localizable {
		switch self {
		case .general: .tabGeneral
		case .calendars: .tabCalendars
		case .canvas: .tabCanvas
		case .about: .tabAbout
		}
	}

	var symbolName: String {
		switch self {
		case .general: "gearshape"
		case .calendars: "calendar"
		case .canvas: "graduationcap"
		case .about: "info.circle"
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

	/// Called after the tab changes, so the window can update the tab buttons.
	@ObservationIgnored public var onTabChange: ((SettingsTab) -> Void)?

	public init(tab: SettingsTab = .general) {
		self.tab = tab
	}
}
