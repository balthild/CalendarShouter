import AppKit
import SwiftUI

/// An AppKit control reports no text baseline, so `firstTextBaseline` would otherwise align its
/// bottom edge with the surrounding text's baseline. This is how far below the baseline the
/// button's bottom edge belongs instead.
private let radioBaselineInset: CGFloat = 4

/// A radio button backed by AppKit.
///
/// SwiftUI has no radio toggle style. The nearest thing, `Picker`'s `.radioGroup`, hosts each
/// option's content inside a button, so a label holding text fields would never receive their
/// clicks. `NSButton` is the real control, and brings its own drawing, focus ring, keyboard
/// handling and radio-button accessibility along with it.
struct RadioButton: View {
	@Binding var isOn: Bool
	let label: String
	var isEnabled = true

	var body: some View {
		Control(isOn: $isOn, label: label, isEnabled: isEnabled)
			// Without this the representable accepts the whole proposed size, and `NSButton`
			// draws its radio at the leading edge of that frame with its baseline at the bottom,
			// leaving the button and the text in opposite corners of the row.
			.fixedSize()
			.alignmentGuide(.firstTextBaseline) { $0[.bottom] - radioBaselineInset }
	}

	private struct Control: NSViewRepresentable {
		@Binding var isOn: Bool
		let label: String
		let isEnabled: Bool

		func makeCoordinator() -> Coordinator {
			Coordinator(isOn: $isOn)
		}

		func makeNSView(context: Context) -> NSButton {
			let button = NSButton(
				radioButtonWithTitle: "",
				target: context.coordinator,
				action: #selector(Coordinator.activate)
			)
			button.setAccessibilityLabel(label)
			return button
		}

		func updateNSView(_ button: NSButton, context: Context) {
			context.coordinator.isOn = $isOn
			button.state = isOn ? .on : .off
			button.isEnabled = isEnabled
			button.setAccessibilityLabel(label)
		}

		@MainActor
		final class Coordinator: NSObject {
			var isOn: Binding<Bool>

			init(isOn: Binding<Bool>) {
				self.isOn = isOn
			}

			/// A radio in a group is never turned off by clicking it, and AppKit would toggle
			/// this one, so the binding only ever goes on.
			@objc func activate() {
				isOn.wrappedValue = true
			}
		}
	}
}
