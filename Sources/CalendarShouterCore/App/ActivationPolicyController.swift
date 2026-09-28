import AppKit

/// Keeps the Dock icon hidden while the app runs as a background agent, showing
/// it only while the settings window is open.
///
/// The app's `Info.plist` sets `LSUIElement`, so the default policy is
/// `.accessory`; switching to `.regular` while a window is open is what makes the
/// app appear in the Dock and the application switcher for that moment.
@MainActor
public final class ActivationPolicyController {
	private var openWindowCount = 0

	public init() {}

	public func windowDidOpen() {
		openWindowCount += 1
		applyPolicy()
	}

	public func windowDidClose() {
		openWindowCount = max(0, openWindowCount - 1)
		applyPolicy()
	}

	private func applyPolicy() {
		let policy: NSApplication.ActivationPolicy = openWindowCount > 0 ? .regular : .accessory
		guard NSApp.activationPolicy() != policy else { return }
		_ = NSApp.setActivationPolicy(policy)
	}
}
