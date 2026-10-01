import SwiftUI

/// The contents of a panel that summarises a batch of missed reminders.
///
/// One action applies to the whole batch: individual rows are listed for context,
/// but the user is not asked to answer each one.
struct MissedRemindersView: View {
	let fires: [ReminderFire]
	let onIgnoreAll: @MainActor () -> Void
	let onSnoozeAll: @MainActor (SnoozeOption) -> Void

	@State private var snoozeOption: SnoozeOption = .fiveMinutes

	var body: some View {
		VStack(alignment: .leading, spacing: 0) {
			header
			list
			Divider()
			actions
		}
		.frame(width: ReminderWindowController.panelWidth)
	}

	private var header: some View {
		HStack(alignment: .firstTextBaseline, spacing: 8) {
			Text(localizable: .missedReminders)
				.font(.title3.weight(.semibold))
			Text("\(fires.count)")
				.font(.callout.weight(.medium))
				.foregroundStyle(.secondary)
		}
		.frame(maxWidth: .infinity, alignment: .leading)
		.padding(.horizontal, 20)
		.padding(.top, 20)
		.padding(.bottom, 14)
	}

	private var list: some View {
		ScrollView {
			VStack(alignment: .leading, spacing: 12) {
				ForEach(fires) { fire in
					row(for: fire)
				}
			}
			.frame(maxWidth: .infinity, alignment: .leading)
			.padding(.horizontal, 20)
		}
		.frame(maxHeight: 240)
		.padding(.bottom, 18)
	}

	private func row(for fire: ReminderFire) -> some View {
		HStack(alignment: .top, spacing: 8) {
			Circle()
				.fill(Color(rgb: fire.event.calendar.color))
				.frame(width: 8, height: 8)
				.padding(.top, 5)
			VStack(alignment: .leading, spacing: 2) {
				Text(fire.event.displayTitle)
					.font(.callout)
					.fixedSize(horizontal: false, vertical: true)
				Text(fire.event.reminderTimeText)
					.font(.caption)
					.foregroundStyle(.secondary)
			}
		}
	}

	private var actions: some View {
		HStack(spacing: 12) {
			Button(action: onIgnoreAll) {
				Text(localizable: .ignoreAll)
			}

			Spacer(minLength: 0)

			Picker(selection: $snoozeOption) {
				ForEach(SnoozeOption.allCases) { option in
					Text(localizable: option.localizedLabel).tag(option)
				}
			} label: {
				EmptyView()
			}
			.labelsHidden()
			.frame(width: 110)

			Button {
				onSnoozeAll(snoozeOption)
			} label: {
				Text(localizable: .snoozeAll)
			}
			.keyboardShortcut(.defaultAction)
		}
		.padding(.horizontal, 20)
		.padding(.vertical, 14)
	}
}
