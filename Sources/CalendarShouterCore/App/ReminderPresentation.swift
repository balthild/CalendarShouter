import Foundation

/// Decides how a batch of due reminders is presented.
public enum ReminderPresentation {
	/// How many missed reminders must pile up before they are collapsed into a
	/// single summary panel.
	public static let backlogThreshold = 3

	/// The reminders that were missed while the app was not watching and whose event
	/// has already ended.
	///
	/// A missed reminder whose event is still running is worth interrupting for one
	/// by one; one whose event is over is not, so those are the ones collapsed.
	public static func endedMissed(_ fires: [ReminderFire], now: Date) -> [ReminderFire] {
		fires.filter { !$0.isSnooze && $0.isLate && $0.event.endDate <= now }
	}

	/// Whether `fires` holds enough ended missed reminders to collapse.
	public static func isBacklog(_ fires: [ReminderFire], now: Date) -> Bool {
		endedMissed(fires, now: now).count > backlogThreshold
	}
}
