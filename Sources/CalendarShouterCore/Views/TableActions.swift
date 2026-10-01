import AppKit
import SwiftUI

/// The strip of `+` and `−` that sits under a table.
///
/// SwiftUI's `Table` has no footer, so this attaches with `safeAreaInset`.
///
/// The selection is a `Binding`, not a pre-computed closure: a binding reads live storage, so
/// `−` sees the current selection even when this view is not rebuilt.
struct TableActions<ID: Hashable>: View {
	let addHelp: String.Localizable
	let removeHelp: String.Localizable
	let onAdd: () -> Void
	/// The table's selection; nothing selected means there is nothing to remove.
	let selection: Binding<ID?>
	let onRemove: (ID) -> Void

	@Environment(\.displayScale) private var displayScale

	var body: some View {
		HStack(spacing: 4) {
			Button(action: onAdd) {
				Image(systemName: "plus")
					.frame(width: 16, height: 16)
					.contentShape(Rectangle())
			}
			.help(String(localizable: addHelp))

			Divider()
				.frame(height: 16)

			Button {
				guard let identifier = selection.wrappedValue else { return }
				onRemove(identifier)
			} label: {
				Image(systemName: "minus")
					.frame(width: 16, height: 16)
					.contentShape(Rectangle())
			}
			.disabled(selection.wrappedValue == nil)
			.help(String(localizable: removeHelp))

			Spacer(minLength: 0)
		}
		.buttonStyle(TableActionButtonStyle())
		.imageScale(.small)
		.padding(.horizontal, 6)
		.padding(.vertical, 4)
		.background(.primary.opacity(0.037))
		.overlay(alignment: .top) {
			Rectangle()
				.fill(Color(nsColor: .separatorColor))
				.frame(height: 1 / displayScale)
		}
	}
}

/// A one-row table standing in for a table with nothing in it.
///
/// A `Table` draws nothing at all when its data is empty — not even the column headers — so
/// the placeholder has to be a real row.
struct EmptyTable: View {
	let actions: TableActions<Never>

	private struct Placeholder: Identifiable {
		var id: Int { 0 }
	}

	var body: some View {
		Table([Placeholder()]) {
			TableColumn("") { _ in
				Text(localizable: .noItems)
					.foregroundStyle(.secondary)
					.frame(maxWidth: .infinity, alignment: .center)
			}
		}
		.tableColumnHeaders(.hidden)
		.safeAreaInset(edge: .bottom, spacing: 0) {
			actions
		}
	}
}

/// A table action icon that darkens while it is held down.
///
/// `.borderless` draws no background to darken, so the press shows in the glyph itself.
/// Replacing that style also means inheriting its disabled appearance no longer happens for
/// free, hence the environment read.
private struct TableActionButtonStyle: ButtonStyle {
	func makeBody(configuration: Configuration) -> some View {
		Icon(configuration: configuration)
	}

	private struct Icon: View {
		let configuration: ButtonStyle.Configuration

		@Environment(\.isEnabled) private var isEnabled

		var body: some View {
			configuration.label
				.foregroundStyle(tint)
				.animation(.easeOut(duration: 0.1), value: configuration.isPressed)
		}

		private var tint: Color {
			guard isEnabled else { return .secondary.opacity(0.5) }
			return configuration.isPressed ? .primary.opacity(0.8) : .secondary
		}
	}
}
