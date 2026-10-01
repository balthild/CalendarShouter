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
					.font(.system(size: 11, weight: .medium))
					.frame(width: 20, height: 20)
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
					.font(.system(size: 11, weight: .medium))
					.frame(width: 20, height: 20)
					.contentShape(Rectangle())
			}
			.disabled(selection.wrappedValue == nil)
			.help(String(localizable: removeHelp))

			Spacer(minLength: 0)
		}
		.buttonStyle(TableActionButtonStyle())
		.frame(height: 24)
		.padding(.horizontal, 5)
		.background(.primary.opacity(0.037))
		.overlay(alignment: .top) {
			Rectangle()
				.fill(Color(nsColor: .separatorColor))
				.frame(height: 1 / displayScale)
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
			guard isEnabled else { return .secondary.opacity(0.6) }
			return .primary.opacity(configuration.isPressed ? 0.9 : 0.7)
		}
	}
}
