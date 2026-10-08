import SwiftUI

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
								.toggleStyle(.tintedCheckbox(tint: calendar.color))
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
		// A grouped form like every other pane state. The toolbar only draws its opaque material
		// when something opaque sits behind the pane's scroll view: a plain `ScrollView`, a
		// `.columns` form, or a hidden scroll content background all leave it translucent instead.
		SettingsForm {
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
			.padding(.vertical, 32)
		}
	}

	private func binding(for calendar: CalendarInfo) -> Binding<Bool> {
		Binding(
			get: { store.isReminderEnabled(forCalendarID: calendar.id) },
			set: { store.setReminderEnabled($0, forCalendarID: calendar.id) }
		)
	}
}
