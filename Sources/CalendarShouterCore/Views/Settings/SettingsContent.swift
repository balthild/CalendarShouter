import SwiftUI

/// Hosts the pane for the selected tab.
struct SettingsContent: View {
	@Bindable var selection: SettingsSelection
	@Bindable var store: SettingsStore
	@Bindable var loginItemController: LoginItemController
	let calendarService: EventKitCalendarService
	let canvasService: CanvasService
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
				soundCatalog: soundCatalog,
				onRemindersAccessNeeded: onRemindersAccessNeeded,
				onPreviewSound: onPreviewSound
			)
		case .calendars:
			CalendarsSettingsPane(
				store: store,
				calendarService: calendarService,
				onRequestAccess: onRequestCalendarAccess,
				onOpenPrivacySettings: onOpenCalendarPrivacySettings
			)
		case .canvas:
			CanvasSettingsPane(store: store, canvasService: canvasService)
		case .about:
			AboutSettingsPane()
		}
	}
}
