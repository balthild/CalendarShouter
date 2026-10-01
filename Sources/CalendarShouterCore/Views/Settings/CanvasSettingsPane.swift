import AppKit
import SwiftUI
import WebKit

struct CanvasSettingsPane: View {
	@Bindable var store: SettingsStore
	let canvasService: CanvasService

	@State private var domainPrompt: DomainPrompt?
	@State private var editingRule: CanvasReminderRule?
	@State private var selectedAccountID: CanvasAccount.ID?
	@State private var selectedRuleID: CanvasReminderRule.ID?

	/// Identifies the add-account sheet; empty means "start from scratch".
	private struct DomainPrompt: Identifiable {
		let id: String
	}

	var body: some View {
		SettingsForm {
			accountsSection
			reminderRulesSection

			ForEach(Array(store.canvasAccounts.enumerated()), id: \.element.id) { index, account in
				courseSection(for: account, isFirst: index == 0)
			}
		}
		.sheet(item: $domainPrompt) { prompt in
			AddCanvasAccountSheet(canvasService: canvasService, initialDomain: prompt.id)
		}
		.sheet(item: $editingRule) { rule in
			CanvasReminderRuleEditor(rule: rule) { saved in
				upsert(saved)
			}
		}
	}

	// MARK: - Accounts

	@ViewBuilder
	private var accountsSection: some View {
		Section {
			if store.canvasAccounts.isEmpty {
				emptyAccountsTable
			} else {
				accountsTable
			}
		} header: {
			Text(localizable: .canvasAccountsHeader)
				.font(.headline)
				// Section headers would otherwise be upper-cased.
				.textCase(nil)
		}
	}

	private var accountsTable: some View {
		Table(store.canvasAccounts, selection: $selectedAccountID) {
			TableColumn(String(localizable: .canvasAccountColumn)) { account in
				accountLabel(account)
			}
			TableColumn(String(localizable: .canvasDomainColumn)) { account in
				Text(account.domain)
					.foregroundStyle(.secondary)
			}
		}
		// Attached to the table rather than placed beside it in its own row: a form row
		// has a minimum height, so a short row of buttons would sit in a box far taller
		// than its content.
		.safeAreaInset(edge: .bottom, spacing: 0) {
			TableActions(
				addHelp: .canvasAddAccount,
				removeHelp: .canvasRemoveAccount,
				onAdd: { domainPrompt = DomainPrompt(id: "") },
				selection: $selectedAccountID,
				onRemove: removeAccount
			)
		}
	}

	private func removeAccount(_ identifier: CanvasAccount.ID) {
		guard let account = store.canvasAccounts.first(where: { $0.id == identifier }) else { return }
		canvasService.removeAccount(account)
		selectedAccountID = nil
	}

	private var emptyAccountsTable: some View {
		EmptyTable(
			actions: TableActions(
				addHelp: .canvasAddAccount,
				removeHelp: .canvasRemoveAccount,
				onAdd: { domainPrompt = DomainPrompt(id: "") },
				// No selection, so − stays disabled.
				selection: .constant(nil),
				onRemove: { _ in }
			)
		)
	}

	@ViewBuilder
	private func accountLabel(_ account: CanvasAccount) -> some View {
		HStack(spacing: 6) {
			Text(account.userName)
			if canvasService.needsReauthentication.contains(account.id) {
				Image(systemName: "exclamationmark.triangle.fill")
					.foregroundStyle(.yellow)
					.help(String(localizable: .canvasNeedsSignIn))
			}
		}
	}

	// MARK: - Reminder times

	@ViewBuilder
	private var reminderRulesSection: some View {
		Section {
			if store.canvasReminderRules.isEmpty {
				emptyTable
			} else {
				reminderRulesTable
			}
		} header: {
			VStack(alignment: .leading, spacing: 4) {
				Text(localizable: .canvasReminderTimesHeader)
					.font(.headline)
					.textCase(nil)
				Text(localizable: .canvasReminderTimesCaption)
					.font(.subheadline)
					.foregroundStyle(.secondary)
					.textCase(nil)
			}
		}
	}

	private var reminderRulesTable: some View {
		Table(store.canvasReminderRules.sorted(), selection: $selectedRuleID) {
			TableColumn(String(localizable: .canvasReminderRuleColumn)) { rule in
				Text(CanvasRuleFormatting.description(of: rule))
			}
		}
		// `primaryAction` can only be set by `contextMenu`.
		.contextMenu(forSelectionType: CanvasReminderRule.ID.self) { _ in
			EmptyView()
		} primaryAction: { identifiers in
			editingRule = rule(in: identifiers)
		}
		.safeAreaInset(edge: .bottom, spacing: 0) {
			TableActions(
				addHelp: .canvasAddReminderRule,
				removeHelp: .canvasRemoveReminderRule,
				onAdd: { editingRule = CanvasReminderRule(kind: .beforeDue) },
				selection: $selectedRuleID,
				onRemove: { remove([$0]) }
			)
		}
	}

	private var emptyTable: some View {
		EmptyTable(
			actions: TableActions(
				addHelp: .canvasAddReminderRule,
				removeHelp: .canvasRemoveReminderRule,
				onAdd: { editingRule = CanvasReminderRule(kind: .beforeDue) },
				// No selection, so − stays disabled.
				selection: .constant(nil),
				onRemove: { _ in }
			)
		)
	}

	private func upsert(_ rule: CanvasReminderRule) {
		if let index = store.canvasReminderRules.firstIndex(where: { $0.id == rule.id }) {
			store.canvasReminderRules[index] = rule
		} else {
			store.canvasReminderRules.append(rule)
		}
	}

	private func rule(in identifiers: Set<CanvasReminderRule.ID>) -> CanvasReminderRule? {
		guard let identifier = identifiers.first else { return nil }
		return store.canvasReminderRules.first { $0.id == identifier }
	}

	private func remove(_ identifiers: Set<CanvasReminderRule.ID>) {
		store.canvasReminderRules.removeAll { identifiers.contains($0.id) }
		selectedRuleID = nil
	}

	// MARK: - Courses

	@ViewBuilder
	private func courseSection(for account: CanvasAccount, isFirst: Bool) -> some View {
		let courses = canvasService.courses(forAccountID: account.id)
		Section {
			VStack(alignment: .leading, spacing: 10) {
				HStack(spacing: 8) {
					Text(account.userName)
						.font(.subheadline)
						.foregroundStyle(.secondary)
						.fontWeight(.medium)
					Text(account.domain)
						.font(.caption)
						.foregroundStyle(.tertiary)

					if canvasService.needsReauthentication.contains(account.id) {
						Button {
							domainPrompt = DomainPrompt(id: account.domain)
						} label: {
							Text(localizable: .canvasSignInAgain)
								.font(.caption)
						}
						.buttonStyle(.link)
					}
				}

				if courses.isEmpty {
					Text(
						canvasService.isRefreshing
							? String(localizable: .canvasLoadingCourses)
							: String(localizable: .canvasNoCourses)
					)
					.font(.subheadline)
					.foregroundStyle(.secondary)
				} else {
					ForEach(courses) { course in
						Toggle(isOn: binding(for: course)) {
							Text(course.name)
								.foregroundStyle(Color.primary.opacity(0.85))
						}
						.toggleStyle(.tintedCheckbox(tint: CanvasPalette.courseColor))
					}
				}
			}
			.frame(maxWidth: .infinity, alignment: .leading)
		} header: {
			if isFirst {
				courseListHeader
			}
		}
	}

	private var courseListHeader: some View {
		VStack(alignment: .leading, spacing: 4) {
			Text(localizable: .canvasEnableCourses)
				.font(.headline)
				.textCase(nil)
			Text(localizable: .canvasOnlyEnabledCourses)
				.font(.subheadline)
				.foregroundStyle(.secondary)
				.textCase(nil)
		}
	}

	private func binding(for course: CanvasCourse) -> Binding<Bool> {
		Binding(
			get: { store.isCanvasReminderEnabled(forCourseID: course.id) },
			set: { store.setCanvasReminderEnabled($0, forCourseID: course.id) }
		)
	}
}

// MARK: - Add account

/// A sheet where the Canvas OAuth sign-in process takes place.
private struct AddCanvasAccountSheet: View {
	let canvasService: CanvasService

	@Environment(\.dismiss) private var dismiss
	@State private var domain: String
	@State private var pending: CanvasService.PendingSignIn?
	@State private var message: String?
	@State private var isWorking = false

	init(canvasService: CanvasService, initialDomain: String) {
		self.canvasService = canvasService
		_domain = State(initialValue: initialDomain)
	}

	var body: some View {
		VStack(alignment: .leading, spacing: 16) {
			if let pending, let url = authorizationURL(for: pending) {
				Text(localizable: .canvasAuthorizeInstruction)
					.font(.callout)
					.foregroundStyle(.secondary)

				CanvasAuthorizationView(
					url: url,
					onCode: { finish(pending: pending, code: $0) },
					onFailure: { _ in fail(with: .canvasErrorSignInFailed) }
				)
				.frame(minWidth: 720, minHeight: 640)
			} else {
				Text(localizable: .canvasAddAccountPrompt)
				TextField("https://canvas.school.edu", text: $domain)
					.textFieldStyle(.roundedBorder)
					.onSubmit { verify() }
			}

			if let message {
				Text(message)
					.font(.footnote)
					.foregroundStyle(.red)
			}

			HStack {
				if isWorking {
					ProgressView()
						.controlSize(.small)
				}
				Spacer()
				Button {
					dismiss()
				} label: {
					Text(localizable: .canvasCancel)
				}
				.keyboardShortcut(.cancelAction)

				if pending == nil {
					Button {
						verify()
					} label: {
						Text(localizable: .canvasContinue)
					}
					.keyboardShortcut(.defaultAction)
					.disabled(isWorking || domain.trimmingCharacters(in: .whitespaces).isEmpty)
				}
			}
		}
		.frame(width: pending == nil ? 360 : 720)
		.padding(20)
	}

	private func authorizationURL(for pending: CanvasService.PendingSignIn) -> URL? {
		CanvasOAuth.authorizationURL(domain: pending.domain, credentials: pending.credentials)
	}

	private func verify() {
		guard !isWorking else { return }
		isWorking = true
		message = nil

		Task { @MainActor in
			do {
				pending = try await canvasService.verifyDomain(domain)
			} catch {
				fail(with: Self.key(for: error))
			}
			isWorking = false
		}
	}

	private func finish(pending: CanvasService.PendingSignIn, code: String) {
		guard !isWorking else { return }
		isWorking = true

		Task { @MainActor in
			do {
				_ = try await canvasService.signIn(pending, code: code)
				dismiss()
			} catch {
				self.pending = nil
				fail(with: Self.key(for: error))
			}
			isWorking = false
		}
	}

	private func fail(with key: String.Localizable) {
		message = String(localizable: key)
	}

	private static func key(for error: Error) -> String.Localizable {
		switch error {
		case CanvasService.SignInError.unknownDomain, CanvasService.SignInError.domainNotAuthorized:
			return .canvasErrorDomain
		case CanvasService.SignInError.unsupportedClient:
			return .canvasErrorUnsupportedClient
		case CanvasService.SignInError.notSignedIn, CanvasService.SignInError.cancelled,
			CanvasService.SignInError.failed, CanvasAPIError.decoding, CanvasAPIError.invalidURL,
			CanvasAPIError.invalidResponse:
			return .canvasErrorSignInFailed
		case CanvasAPIError.http:
			return .canvasErrorServer
		default:
			return .canvasErrorGeneric
		}
	}
}

/// Canvas's sign-in page, watched for the redirect that carries the authorization code.
private struct CanvasAuthorizationView: NSViewRepresentable {
	let url: URL
	let onCode: @MainActor (String) -> Void
	let onFailure: @MainActor (String) -> Void

	func makeCoordinator() -> Coordinator {
		Coordinator(onCode: onCode, onFailure: onFailure)
	}

	func makeNSView(context: Context) -> WKWebView {
		let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
		webView.navigationDelegate = context.coordinator
		webView.load(URLRequest(url: url))
		return webView
	}

	func updateNSView(_ webView: WKWebView, context: Context) {}

	@MainActor
	final class Coordinator: NSObject, WKNavigationDelegate {
		private let onCode: @MainActor (String) -> Void
		private let onFailure: @MainActor (String) -> Void
		/// Set once the code has been seen, so the cancelled navigation that follows does
		/// not get reported as a failure.
		private var isFinished = false

		init(
			onCode: @escaping @MainActor (String) -> Void,
			onFailure: @escaping @MainActor (String) -> Void
		) {
			self.onCode = onCode
			self.onFailure = onFailure
		}

		func webView(
			_ webView: WKWebView,
			decidePolicyFor navigationAction: WKNavigationAction
		) async -> WKNavigationActionPolicy {
			guard !isFinished, let url = navigationAction.request.url else { return .allow }

			if let code = CanvasOAuth.authorizationCode(from: url) {
				isFinished = true
				onCode(code)
				return .cancel
			}
			if let error = CanvasOAuth.error(from: url) {
				isFinished = true
				onFailure(error)
				return .cancel
			}
			return .allow
		}

		func webView(
			_ webView: WKWebView,
			didFailProvisionalNavigation navigation: WKNavigation?,
			withError error: Error
		) {
			guard !isFinished, (error as NSError).code != NSURLErrorCancelled else { return }
			isFinished = true
			onFailure(error.localizedDescription)
		}
	}
}

// MARK: - Rule editor

/// Edits one reminder rule.
///
/// The options are drawn by hand rather than with a `.radioGroup` picker: a picker's option
/// labels are hosted inside a button, which would swallow the clicks the fields need.
private struct CanvasReminderRuleEditor: View {
	let rule: CanvasReminderRule
	let onSave: (CanvasReminderRule) -> Void

	@Environment(\.dismiss) private var dismiss
	@State private var draft: CanvasReminderRule

	init(rule: CanvasReminderRule, onSave: @escaping (CanvasReminderRule) -> Void) {
		self.rule = rule
		self.onSave = onSave
		_draft = State(initialValue: rule)
	}

	var body: some View {
		VStack(alignment: .leading) {
			Text(localizable: .canvasReminderRuleEditorTitle)
				.font(.headline)

			VStack(alignment: .leading, spacing: 8) {
				daysBeforeRow
				onDueDayRow
				beforeDueRow
			}

			Spacer()

			HStack {
				Spacer()
				Button {
					dismiss()
				} label: {
					Text(localizable: .canvasCancel)
				}
				.keyboardShortcut(.cancelAction)

				Button {
					onSave(draft.normalized)
					dismiss()
				} label: {
					Text(localizable: .canvasSave)
				}
				.keyboardShortcut(.defaultAction)
			}
		}
		.frame(width: 360)
		.padding(.horizontal, 20)
		.padding(.vertical, 20)
	}

	private var daysBeforeRow: some View {
		CanvasRuleOption(kind: .daysBefore, selection: $draft.kind) {
			HStack(spacing: 6) {
				CanvasRuleLabel(label: .canvasRuleDaysTemplate, index: 0)
				HStack(spacing: 3) {
					TextField("", value: $draft.days, format: .number)
						.frame(width: 44)
						.multilineTextAlignment(.trailing)
						.disabled(draft.kind != .daysBefore)
					Stepper("", value: $draft.days, in: 0...31)
						.labelsHidden()
						.fixedSize()
				}
				CanvasRuleLabel(label: .canvasRuleDaysTemplate, index: 1)
				CanvasTimeField(time: $draft.time)
					.disabled(draft.kind != .daysBefore)
				CanvasRuleLabel(label: .canvasRuleDaysTemplate, index: 2)
			}
		}
	}

	private var onDueDayRow: some View {
		CanvasRuleOption(kind: .onDueDay, selection: $draft.kind) {
			HStack(spacing: 6) {
				CanvasRuleLabel(label: .canvasRuleOnDueDayTemplate, index: 0)
				CanvasTimeField(time: $draft.time)
					.disabled(draft.kind != .onDueDay)
				CanvasRuleLabel(label: .canvasRuleOnDueDayTemplate, index: 1)
			}
		}
	}

	private var beforeDueRow: some View {
		CanvasRuleOption(kind: .beforeDue, selection: $draft.kind) {
			HStack(spacing: 6) {
				CanvasRuleLabel(label: .canvasRuleOffsetTemplate, index: 0)
				Picker(selection: $draft.minutes) {
					ForEach(CanvasReminderRule.offsetChoices, id: \.self) { minutes in
						Text(CanvasRuleFormatting.duration(minutes: minutes)).tag(minutes)
					}
				} label: {
					EmptyView()
				}
				.labelsHidden()
				.pickerStyle(.menu)
				.fixedSize()
				.disabled(draft.kind != .beforeDue)
				CanvasRuleLabel(label: .canvasRuleOffsetTemplate, index: 1)
			}
		}
	}
}

private struct CanvasRuleOption<Label: View>: View {
	let kind: CanvasReminderRule.Kind
	@Binding var selection: CanvasReminderRule.Kind
	@ViewBuilder var label: Label

	var body: some View {
		HStack(alignment: .firstTextBaseline, spacing: 8) {
			RadioButton(
				isOn: Binding(
					get: { selection == kind },
					set: { if $0 { selection = kind } }
				),
				label: CanvasRuleFormatting.title(of: kind)
			)

			label.contentShape(Rectangle())
				.onTapGesture { selection = kind }

			Spacer(minLength: 0)
		}
	}
}

/// One stretch of a rule row's label.
///
/// A row's label is a single localized string with `{}` wherever one of the row's input
/// controls goes, one placeholder per control, so the wording keeps its order under
/// translation. `{}` is used rather than `%@`, which the string catalog reads as a format
/// specifier. A stretch the template does not supply — what a translator who drops a
/// placeholder produces — draws nothing, as does the trailing stretch when the last
/// placeholder ends the template.
private struct CanvasRuleLabel: View {
	let label: String.Localizable
	let index: Int

	var body: some View {
		if let text = CanvasRuleFormatting.label(of: label, at: index) {
			Text(text)
		}
	}
}

/// A time-of-day field, backed by a date on the current day.
private struct CanvasTimeField: View {
	@Binding var time: TimeOfDay

	var body: some View {
		DatePicker(selection: binding, displayedComponents: .hourAndMinute) {
			EmptyView()
		}
		.labelsHidden()
		.fixedSize()
	}

	private var binding: Binding<Date> {
		Binding(
			get: { CanvasRuleFormatting.referenceDate(for: time) },
			set: { time = CanvasRuleFormatting.timeOfDay(from: $0) }
		)
	}
}

// MARK: - Formatting

enum CanvasRuleFormatting {
	static func title(of kind: CanvasReminderRule.Kind) -> String {
		switch kind {
		case .daysBefore: String(localizable: .canvasRuleDaysTitle)
		case .onDueDay: String(localizable: .canvasRuleOnDueDayTitle)
		case .beforeDue: String(localizable: .canvasRuleOffsetTitle)
		}
	}

	/// The rule as one line, for the table.
	static func description(of rule: CanvasReminderRule) -> String {
		let rule = rule.normalized
		switch rule.kind {
		case .daysBefore:
			return String(localizable: .canvasRuleDaysFormat(rule.days, timeText(rule.time)))
		case .onDueDay:
			return String(localizable: .canvasRuleOnDueDayFormat(timeText(rule.time)))
		case .beforeDue:
			return String(localizable: .canvasRuleOffsetFormat(duration(minutes: rule.minutes)))
		}
	}

	static func timeText(_ time: TimeOfDay) -> String {
		referenceDate(for: time).formatted(date: .omitted, time: .shortened)
	}

	/// The `index`-th stretch of a rule template, with the space around its `{}` trimmed away,
	/// or nil when there is nothing to draw there.
	static func label(of template: String.Localizable, at index: Int) -> String? {
		let stretches = String(localizable: template)
			.components(separatedBy: "{}")
			.map { $0.trimmingCharacters(in: .whitespaces) }
		guard stretches.indices.contains(index), !stretches[index].isEmpty else { return nil }
		return stretches[index]
	}

	/// Abbreviated on purpose: a unit word would need English plurals, which this app's
	/// string catalog cannot express.
	static func duration(minutes: Int) -> String {
		if minutes < 60 {
			return String(localizable: .canvasDurationMinutes(minutes))
		}
		if minutes % (24 * 60) == 0 {
			return String(localizable: .canvasDurationDays(minutes / (24 * 60)))
		}
		return String(localizable: .canvasDurationHours(minutes / 60))
	}

	static func referenceDate(for time: TimeOfDay) -> Date {
		let calendar = Calendar.current
		var components = calendar.dateComponents([.year, .month, .day], from: Date())
		components.hour = time.hour
		components.minute = time.minute
		return calendar.date(from: components) ?? Date()
	}

	static func timeOfDay(from date: Date) -> TimeOfDay {
		let components = Calendar.current.dateComponents([.hour, .minute], from: date)
		return TimeOfDay(hour: components.hour ?? 9, minute: components.minute ?? 0)
	}
}
