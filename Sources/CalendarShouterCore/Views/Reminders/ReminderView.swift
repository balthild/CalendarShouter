import SwiftUI

/// The contents of a reminder panel.
struct ReminderView: View {
	let fire: ReminderFire
	let onIgnore: @MainActor () -> Void
	let onSnooze: @MainActor (SnoozeOption) -> Void

	@State private var snoozeOption: SnoozeOption = .fiveMinutes

	var body: some View {
		VStack(alignment: .leading, spacing: 0) {
			header
			details
			Divider()
			actions
		}
		.frame(width: ReminderWindowController.panelWidth)
	}

	private var header: some View {
		VStack(alignment: .leading, spacing: 8) {
			HStack(spacing: 6) {
				Circle()
					.fill(Color(rgb: fire.event.calendar.color))
					.frame(width: 9, height: 9)
				Text(fire.event.calendar.title)
					.font(.caption)
					.foregroundStyle(.secondary)
			}

			Text(fire.event.displayTitle)
				.font(.title2.weight(.semibold))
				.fixedSize(horizontal: false, vertical: true)
		}
		.frame(maxWidth: .infinity, alignment: .leading)
		.padding(.horizontal, 20)
		.padding(.top, 20)
		.padding(.bottom, 14)
	}

	@ViewBuilder
	private var details: some View {
		VStack(alignment: .leading, spacing: 10) {
			detailRow(systemImage: "clock", text: fire.event.reminderTimeText)

			if let location = fire.event.location {
				detailRow(systemImage: "mappin.and.ellipse", text: location)
			}

			if let notes = fire.event.notes {
				notesSection(notes)
			}
		}
		.frame(maxWidth: .infinity, alignment: .leading)
		.padding(.horizontal, 20)
		.padding(.bottom, 18)
	}

	private func detailRow(systemImage: String, text: String) -> some View {
		HStack(alignment: .firstTextBaseline, spacing: 6) {
			Image(systemName: systemImage)
				.font(.callout)
				.foregroundStyle(.secondary)
				.frame(width: 16)
			Text(text)
				.font(.callout)
				.fixedSize(horizontal: false, vertical: true)
		}
		.padding(.leading, -1)
	}

	private func notesSection(_ notes: String) -> some View {
		VStack(alignment: .leading, spacing: 4) {
			Text(localizable: .notes)
				.font(.caption)
				.foregroundStyle(.secondary)
			ScrollView {
				Text(notes)
					.font(.callout)
					.frame(maxWidth: .infinity, alignment: .leading)
			}
			.frame(maxHeight: 120)
		}
	}

	private var actions: some View {
		HStack(spacing: 12) {
			Button(action: onIgnore) {
				Text(localizable: .ignore)
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
				onSnooze(snoozeOption)
			} label: {
				Text(localizable: .snooze)
			}
			.keyboardShortcut(.defaultAction)
		}
		.padding(.horizontal, 20)
		.padding(.vertical, 16)
	}
}

// MARK: - Shared formatting

extension ReminderEvent {
	/// The event's title, or a placeholder when it has none.
	var displayTitle: String {
		title.isEmpty ? String(localizable: .untitledEvent) : title
	}

	/// The event's time range, as shown on a reminder.
	///
	/// A point in time — a reminder's due time, say — is shown once rather than as a range.
	var reminderTimeText: String {
		guard !isAllDay else { return String(localizable: .allDay) }
		let start = startDate.formatted(.dateTime.month(.abbreviated).day().hour().minute())
		guard startDate != endDate else { return start }
		let end = endDate.formatted(.dateTime.hour().minute())
		return "\(start) – \(end)"
	}
}
