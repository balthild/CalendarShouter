import SwiftUI

/// A one-row table standing in for a table with nothing in it.
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
