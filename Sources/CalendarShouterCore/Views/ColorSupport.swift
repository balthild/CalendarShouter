import SwiftUI

extension Color {
	public init(rgb: RGBColor) {
		self.init(red: rgb.red, green: rgb.green, blue: rgb.blue, opacity: rgb.alpha)
	}
}
