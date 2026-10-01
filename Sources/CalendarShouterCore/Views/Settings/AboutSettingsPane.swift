import AppKit
import SwiftUI

struct AboutSettingsPane: View {
	// Proper nouns: shown as written in every language, so they are not catalog keys.
	private static let projectName = "CalendarShouter"
	private static let author = "Balthild"

	var body: some View {
		SettingsForm {
			Section {
				VStack(spacing: 6) {
					icon
					Text(Self.projectName)
						.font(.headline)
					Text(versionText)
					Text(String(localizable: .aboutMadeBy(Self.author)))
						.font(.subheadline)
				}
				.frame(maxWidth: .infinity)
				.padding(.vertical, 16)

				Text(localizable: .aboutCopyright)
					.font(.footnote)
					.foregroundStyle(.secondary)
					.multilineTextAlignment(.center)
					.frame(maxWidth: .infinity)
			}
		}
	}

	@ViewBuilder
	private var icon: some View {
		if let appIcon = NSApplication.shared.applicationIconImage {
			Image(nsImage: appIcon)
				.resizable()
				.interpolation(.high)
				.frame(width: 80, height: 80)
		}
	}

	/// Read from the bundle, which the Makefile stamps with the release version and build number.
	private var versionText: String {
		let info = Bundle.main.infoDictionary
		let version = info?["CFBundleShortVersionString"] as? String ?? "0.0.0"
		let build = info?["CFBundleVersion"] as? String ?? "1"
		return String(localizable: .aboutVersion(version, build))
	}
}
