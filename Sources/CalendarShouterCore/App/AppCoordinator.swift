import AppKit
import Observation
import SwiftUI

/// Wires the app's controllers together and keeps them in step with settings,
/// calendar changes and system clock changes.
@MainActor
public final class AppCoordinator {
	private let settings: SettingsStore
	private let calendarService: EventKitCalendarService
	private let scheduler: ReminderScheduler
	private let soundPlayer: SoundPlayer
	private let soundCatalog: SoundCatalog
	private let loginItemController: LoginItemController
	private let singleInstance: SingleInstanceController
	private let activationPolicy = ActivationPolicyController()

	/// Observation tokens for system notifications; `nonisolated` so that the
	/// deinitializer can unregister them.
	nonisolated(unsafe) private var systemObservers: [NSObjectProtocol] = []
	private var rollingRefreshTimer: Timer?
	private var soundRateLimiter = SoundRateLimiter()

	private lazy var statusItemController = StatusItemController(
		showSettings: { [weak self] in self?.showSettings() },
		quit: { NSApp.terminate(nil) }
	)

	private lazy var reminderWindowController: ReminderWindowController = {
		let controller = ReminderWindowController()
		controller.onIgnore = { [weak self] fire in self?.scheduler.dismiss(fire) }
		controller.onSnooze = { [weak self] fire, option in
			self?.scheduler.snooze(fire, by: option)
		}
		controller.onIgnoreAll = { [weak self] fires in
			for fire in fires { self?.scheduler.dismiss(fire) }
		}
		controller.onSnoozeAll = { [weak self] fires, option in
			for fire in fires { self?.scheduler.snooze(fire, by: option) }
		}
		return controller
	}()

	private lazy var settingsWindowController = SettingsWindowController(
		activationPolicy: activationPolicy,
		makeContent: { [weak self] selection in
			guard let self else { return AnyView(EmptyView()) }
			return self.makeSettingsContent(selection: selection)
		}
	)

	public init(singleInstance: SingleInstanceController, defaults: UserDefaults = .standard) {
		let settings = SettingsStore(defaults: defaults)
		let calendarService = EventKitCalendarService()

		self.singleInstance = singleInstance
		self.settings = settings
		self.calendarService = calendarService
		self.soundPlayer = SoundPlayer()
		self.soundCatalog = SoundCatalog()
		self.loginItemController = LoginItemController()
		self.scheduler = ReminderScheduler(
			service: calendarService,
			settings: settings,
			defaults: defaults
		)
	}

	deinit {
		for observer in systemObservers {
			NotificationCenter.default.removeObserver(observer)
			NSWorkspace.shared.notificationCenter.removeObserver(observer)
		}
	}

	/// Starts watching calendars and schedules the first reminders.
	public func start() {
		singleInstance.observeShowSettingsRequests { [weak self] in self?.showSettings() }

		observeSettings()
		observeSystemEvents()

		calendarService.onChange = { [weak self] in self?.scheduler.reload() }
		scheduler.onFire = { [weak self] fires in self?.present(fires) }
		loginItemController.onApprovalRequired = { [weak self] in
			self?.presentLoginItemApprovalAlert()
		}
		loginItemController.onAutomationDenied = { [weak self] in
			self?.presentLoginItemAutomationAlert()
		}

		applySettings()
		scheduler.reload()
		requestCalendarAccessIfNeeded()
		requestRemindersAccessIfNeeded()
	}

	/// Brings the settings window to the front.
	public func showSettings() {
		calendarService.refresh()
		loginItemController.refresh()
		settingsWindowController.show()
	}

	/// Presents a synthetic reminder.
	///
	/// Used by the `--demo-reminder` launch argument so the reminder panel can be
	/// inspected without waiting for a real calendar alarm.
	public func presentDemoReminder(after delay: TimeInterval = 1) {
		let startDate = Date().addingTimeInterval(300)
		let event = ReminderEvent(
			id: "demo-event",
			title: String(localizable: .demoEventTitle),
			startDate: startDate,
			endDate: startDate.addingTimeInterval(1800),
			isAllDay: false,
			location: String(localizable: .demoEventLocation),
			notes: String(localizable: .demoEventNotes),
			calendar: CalendarInfo(
				id: "demo-calendar",
				title: String(localizable: .demoCalendarTitle),
				color: RGBColor(red: 0.35, green: 0.45, blue: 0.95),
				account: CalendarAccountRef(id: "demo-account", title: "iCloud", kind: .calDAV)
			),
			fireDates: [Date()]
		)
		let fire = ReminderFire(event: event, fireDate: Date(), isSnooze: false)

		Task { @MainActor [weak self] in
			try? await Task.sleep(for: .seconds(delay))
			self?.present([fire])
		}
	}

	/// Presents a synthetic backlog of missed reminders.
	///
	/// Used by the `--demo-missed-reminders` launch argument so the summary panel can
	/// be inspected without waiting for a real backlog.
	public func presentDemoMissedReminders(after delay: TimeInterval = 1) {
		let now = Date()
		let colors: [RGBColor] = [
			RGBColor(red: 0.35, green: 0.45, blue: 0.95),
			RGBColor(red: 0.90, green: 0.35, blue: 0.35),
			RGBColor(red: 0.30, green: 0.70, blue: 0.45),
			RGBColor(red: 0.95, green: 0.65, blue: 0.20),
			RGBColor(red: 0.60, green: 0.40, blue: 0.85),
		]
		let fires = colors.enumerated().map { index, color -> ReminderFire in
			let start = now.addingTimeInterval(-Double(index + 1) * 3600)
			let event = ReminderEvent(
				id: "demo-missed-\(index)",
				title: "\(String(localizable: .demoEventTitle)) \(index + 1)",
				startDate: start,
				endDate: start.addingTimeInterval(1800),
				isAllDay: false,
				location: nil,
				notes: nil,
				calendar: CalendarInfo(
					id: "demo-calendar-\(index)",
					title: "\(String(localizable: .demoCalendarTitle)) \(index + 1)",
					color: color,
					account: CalendarAccountRef(id: "demo-account", title: "iCloud", kind: .calDAV)
				),
				fireDates: [start]
			)
			return ReminderFire(event: event, fireDate: start, isSnooze: false, isLate: true)
		}

		Task { @MainActor [weak self] in
			try? await Task.sleep(for: .seconds(delay))
			self?.present(fires)
		}
	}

	// MARK: - Settings

	/// Reacts to preference changes.
	///
	/// `withObservationTracking` only reports the *next* change, so the
	/// observation is re-established each time.
	private func observeSettings() {
		withObservationTracking {
			_ = settings.showMenuBarIcon
			_ = settings.showMissedReminders
			_ = settings.enabledCalendarIDs
			_ = settings.includeReminders
			_ = settings.soundName
		} onChange: { [weak self] in
			Task { @MainActor [weak self] in
				self?.applySettings()
				self?.observeSettings()
			}
		}
	}

	private func applySettings() {
		statusItemController.setVisible(settings.showMenuBarIcon)
		scheduler.reload()
	}

	// MARK: - Reminders

	private func present(_ fires: [ReminderFire]) {
		guard !fires.isEmpty else { return }
		if soundRateLimiter.shouldPlay(at: Date()) {
			soundPlayer.play(soundName: settings.soundName)
		}

		let now = Date()
		guard ReminderPresentation.isBacklog(fires, now: now) else {
			reminderWindowController.present(fires)
			return
		}

		let missed = ReminderPresentation.endedMissed(fires, now: now)
		let missedIDs = Set(missed.map(\.id))
		reminderWindowController.present(fires.filter { !missedIDs.contains($0.id) })
		reminderWindowController.presentBacklog(missed)
	}

	// MARK: - Login item

	/// Explains that the login item needs approving and offers to open the relevant pane.
	private func presentLoginItemApprovalAlert() {
		presentSettingsAlert(
			title: String(localizable: .loginItemApprovalTitle),
			message: String(localizable: .loginItemApprovalMessage),
			primaryButton: String(localizable: .openLoginItemsSettings)
		) {
			LoginItemController.openSystemSettingsLoginItems()
		}
	}

	/// Explains that the Automation permission is needed to add the login item.
	private func presentLoginItemAutomationAlert() {
		presentSettingsAlert(
			title: String(localizable: .loginItemAutomationTitle),
			message: String(localizable: .loginItemAutomationMessage),
			primaryButton: String(localizable: .openSystemSettings)
		) {
			Self.openAutomationPrivacySettings()
		}
	}

	/// Presents an informational sheet on the settings window, so it stays attached to the
	/// window the toggle lives in.
	///
	/// Deferred by a task: the toggle's binding starts this in the middle of a SwiftUI update.
	private func presentSettingsAlert(
		title: String,
		message: String,
		primaryButton: String,
		perform: @escaping @MainActor () -> Void
	) {
		Task { @MainActor in
			let alert = NSAlert()
			alert.alertStyle = .informational
			alert.messageText = title
			alert.informativeText = message
			alert.addButton(withTitle: primaryButton)
			alert.addButton(withTitle: String(localizable: .notNow))

			let handle: (NSApplication.ModalResponse) -> Void = { response in
				guard response == .alertFirstButtonReturn else { return }
				perform()
			}

			guard let window = settingsWindowController.presentedWindow else {
				handle(alert.runModal())
				return
			}
			alert.beginSheetModal(for: window) { response in
				MainActor.assumeIsolated { handle(response) }
			}
		}
	}

	private static func openAutomationPrivacySettings() {
		let url = URL(
			string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"
		)
		guard let url else { return }
		NSWorkspace.shared.open(url)
	}

	// MARK: - Calendar and reminder access

	private func requestCalendarAccessIfNeeded() {
		guard calendarService.authorization.isUndetermined else { return }
		requestCalendarAccess()
	}

	/// Asks the user for calendar access.
	///
	/// The system only presents its permission alert when the app has been
	/// launched through LaunchServices; launching the executable directly (as
	/// `make dev` does) is silently refused without ever showing a prompt.
	private func requestCalendarAccess() {
		Task { @MainActor [weak self] in
			guard let self else { return }
			_ = await self.calendarService.requestAccess()
			self.scheduler.reload()
		}
	}

	private func requestRemindersAccessIfNeeded() {
		guard calendarService.remindersAuthorization.isUndetermined else { return }
		requestRemindersAccess()
	}

	private func requestRemindersAccess() {
		Task { @MainActor [weak self] in
			guard let self else { return }
			_ = await self.calendarService.requestRemindersAccess()
			self.scheduler.reload()
		}
	}

	/// Reacts to the user switching reminders on: asks for access if it was never requested,
	/// or explains how to restore it if it was refused.
	private func handleRemindersAccess() {
		switch calendarService.remindersAuthorization {
		case .notDetermined:
			requestRemindersAccess()
		case .denied, .restricted:
			presentRemindersAccessAlert()
		default:
			break
		}
	}

	private func presentRemindersAccessAlert() {
		presentSettingsAlert(
			title: String(localizable: .remindersAccessDeniedTitle),
			message: String(localizable: .remindersAccessDeniedMessage),
			primaryButton: String(localizable: .openSystemSettings)
		) {
			Self.openRemindersPrivacySettings()
		}
	}

	// MARK: - System events

	/// Reminders are recomputed when the clock, the time zone or the machine's
	/// sleep state changes, since a scheduled timer cannot survive those.
	private func observeSystemEvents() {
		let reload: @MainActor @Sendable () -> Void = { [weak self] in self?.scheduler.reload() }
		let notificationCenter = NotificationCenter.default

		for name in [Notification.Name.NSSystemClockDidChange, .NSSystemTimeZoneDidChange] {
			systemObservers.append(
				notificationCenter.addObserver(forName: name, object: nil, queue: .main) { _ in
					MainActor.assumeIsolated { reload() }
				}
			)
		}

		systemObservers.append(
			NSWorkspace.shared.notificationCenter.addObserver(
				forName: NSWorkspace.didWakeNotification,
				object: nil,
				queue: .main
			) { _ in
				MainActor.assumeIsolated { reload() }
			}
		)

		// Keeps the look-ahead window rolling even if no system event occurs.
		let timer = Timer(timeInterval: 3600, repeats: true) { _ in
			MainActor.assumeIsolated { reload() }
		}
		timer.tolerance = 60
		RunLoop.main.add(timer, forMode: .common)
		rollingRefreshTimer = timer
	}

	// MARK: - Views

	/// Builds the settings window's content for the currently selected tab.
	private func makeSettingsContent(selection: SettingsSelection) -> AnyView {
		AnyView(
			SettingsContent(
				selection: selection,
				store: settings,
				loginItemController: loginItemController,
				calendarService: calendarService,
				soundCatalog: soundCatalog,
				onRequestCalendarAccess: { [weak self] in self?.requestCalendarAccess() },
				onOpenCalendarPrivacySettings: { Self.openCalendarPrivacySettings() },
				onRemindersAccessNeeded: { [weak self] in self?.handleRemindersAccess() },
				onPreviewSound: { [weak self] soundName in
					self?.soundPlayer.play(soundName: soundName)
				}
			)
		)
	}

	private static func openCalendarPrivacySettings() {
		let url = URL(
			string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars"
		)
		guard let url else { return }
		NSWorkspace.shared.open(url)
	}

	private static func openRemindersPrivacySettings() {
		let url = URL(
			string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders"
		)
		guard let url else { return }
		NSWorkspace.shared.open(url)
	}
}
