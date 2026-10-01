import SwiftUI

struct GeneralSettingsPane: View {
	@Bindable var store: SettingsStore
	@Bindable var loginItemController: LoginItemController
	let soundCatalog: SoundCatalog
	let onRemindersAccessNeeded: @MainActor () -> Void
	let onPreviewSound: @MainActor (String) -> Void

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
			}

			Section {
				Toggle(isOn: $store.showMissedReminders) {
					Text(localizable: .showMissedReminders)
				}
				Toggle(isOn: remindersBinding) {
					Text(localizable: .includeReminders)
				}
			}

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
