import Foundation

public enum SnoozeOption: Int, CaseIterable, Sendable, Identifiable {
	case fiveMinutes = 5
	case tenMinutes = 10
	case fifteenMinutes = 15
	case thirtyMinutes = 30

	public var id: Int { rawValue }

	public var minutes: Int { rawValue }

	public var timeInterval: TimeInterval { TimeInterval(rawValue) * 60 }

	/// The generated label describing this option's duration.
	var localizedLabel: String.Localizable {
		switch self {
		case .fiveMinutes: .fiveMinutes
		case .tenMinutes: .tenMinutes
		case .fifteenMinutes: .fifteenMinutes
		case .thirtyMinutes: .thirtyMinutes
		}
	}
}
