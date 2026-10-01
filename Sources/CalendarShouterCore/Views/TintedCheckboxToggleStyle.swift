import SwiftUI

extension ToggleStyle where Self == TintedCheckboxToggleStyle {
	static func tintedCheckbox(tint: Color) -> Self {
		Self(tint: tint)
	}

	static func tintedCheckbox(tint: RGBColor) -> Self {
		Self(tint: Color(rgb: tint))
	}
}

/// A checkbox that takes a colour of its own.
///
/// The system checkbox style ignores `.tint` and always uses the accent colour, so the box
/// is drawn here. The label and the click target are unchanged from a checkbox.
struct TintedCheckboxToggleStyle: ToggleStyle {
	nonisolated private var boxSize: CGFloat { 15 }
	nonisolated private var tickLineWidth: CGFloat { 1.36 }
	nonisolated private var tickBorderWidth: CGFloat { 1 }
	nonisolated private var tickInset: CGFloat { 2.5 }

	let tint: Color

	private var edgeColor: Color { Color.black.opacity(0.25) }

	func makeBody(configuration: Configuration) -> some View {
		Button {
			configuration.isOn.toggle()
		} label: {
			HStack(alignment: .firstTextBaseline, spacing: 6) {
				box(isOn: configuration.isOn)
				configuration.label
			}
			.contentShape(Rectangle())
		}
		.buttonStyle(.plain)
		.accessibilityAddTraits(configuration.isOn ? [.isSelected] : [])
	}

	private func box(isOn: Bool) -> some View {
		RoundedRectangle(cornerRadius: 3, style: .continuous)
			.fill(tint)
			.overlay {
				if isOn { tick }
			}
			.overlay {
				RoundedRectangle(cornerRadius: 3, style: .continuous)
					.strokeBorder(edgeColor, lineWidth: 1)
			}
			.frame(width: boxSize, height: boxSize)
			.opacity(isOn ? 1 : 0.5)
			.alignmentGuide(.firstTextBaseline) { ctx in
				ctx[.firstTextBaseline] - boxSize * 0.195
			}
	}

	/// The tick, stroked twice: a thick edge stroke with a thinner white stroke over it, which
	/// leaves an edge of even thickness on every side. (Stamping the glyph at offsets instead
	/// accumulates alpha where the stamps overlap, darkening the edge unevenly.)
	private var tick: some View {
		TickShape()
			.stroke(edgeColor, style: tickStroke(tickLineWidth + 2 * tickBorderWidth))
			.overlay {
				TickShape()
					.stroke(.white, style: tickStroke(tickLineWidth))
			}
			.padding(tickInset)
	}

	private func tickStroke(_ lineWidth: CGFloat) -> StrokeStyle {
		StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round)
	}
}

/// The tick's centreline, in fractions of its box so the proportions can be adjusted by hand.
private struct TickShape: Shape {
	private static let start = CGPoint(x: 0.12, y: 0.58)
	private static let corner = CGPoint(x: 0.38, y: 0.88)
	private static let end = CGPoint(x: 0.9, y: 0.14)

	func path(in rect: CGRect) -> Path {
		var path = Path()
		path.move(to: point(in: rect, Self.start))
		path.addLine(to: point(in: rect, Self.corner))
		path.addLine(to: point(in: rect, Self.end))
		return path
	}

	private func point(in rect: CGRect, _ fraction: CGPoint) -> CGPoint {
		return CGPoint(
			x: rect.minX + rect.width * fraction.x,
			y: rect.minY + rect.height * fraction.y
		)
	}
}
