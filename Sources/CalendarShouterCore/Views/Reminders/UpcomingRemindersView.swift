import SwiftUI

/// The contents of the panel listing the reminders that are due soonest.
///
/// The list is read-only: it exists to show what is coming, not to act on it.
struct UpcomingRemindersView: View {
	let fires: [ReminderFire]
	let onClose: @MainActor () -> Void

	var body: some View {
		VStack(alignment: .leading, spacing: 0) {
			header
			if fires.isEmpty {
				emptyState
			} else {
				list
			}
		}
		.frame(width: UpcomingRemindersWindowController.panelWidth)
	}

	private var header: some View {
		HStack(spacing: 8) {
			Text(localizable: .upcomingReminders)
				.font(.title3.weight(.semibold))

			Spacer(minLength: 0)

			Button(action: onClose) {
				Image(systemName: "xmark")
					.font(.callout)
			}
			.buttonStyle(.plain)
			.foregroundStyle(.secondary)
			.accessibilityLabel(Text(localizable: .close))
		}
		.frame(maxWidth: .infinity, alignment: .leading)
		.padding(.horizontal, 20)
		.padding(.top, 20)
		.padding(.bottom, 14)
	}

	private var emptyState: some View {
		Text(localizable: .noUpcomingReminders)
			.font(.callout)
			.foregroundStyle(.secondary)
			.frame(maxWidth: .infinity, alignment: .leading)
			.padding(.horizontal, 20)
			.padding(.bottom, 20)
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
		.frame(maxHeight: 400)
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
				Text(detailText(for: fire))
					.font(.caption)
					.foregroundStyle(.secondary)
			}
		}
	}

	/// The source and the instant the reminder will be shown.
	///
	/// The fire time rather than the event's own time: one event can carry several
	/// alarms, and showing the event's time would make those rows indistinguishable.
	private func detailText(for fire: ReminderFire) -> String {
		let time = fire.fireDate.formatted(.dateTime.month(.abbreviated).day().hour().minute())
		return "\(fire.event.calendar.title) · \(time)"
	}
}
