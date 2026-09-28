import AppKit
import SwiftUI
import Testing

@testable import CalendarShouterCore

@Suite("Color")
struct ColorSupportTests {
	@Test("Maps each sRGB component and the alpha")
	func mapsComponents() throws {
		let rgb = RGBColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 0.5)

		let resolved = try #require(NSColor(Color(rgb: rgb)).usingColorSpace(.sRGB))

		#expect(abs(resolved.redComponent - 0.2) < 0.01)
		#expect(abs(resolved.greenComponent - 0.4) < 0.01)
		#expect(abs(resolved.blueComponent - 0.6) < 0.01)
		#expect(abs(resolved.alphaComponent - 0.5) < 0.01)
	}
}
