import Foundation
import Testing

@testable import CalendarShouterCore

private let referenceDate = Date(timeIntervalSince1970: 1_700_000_000)

@Suite("SoundRateLimiter")
struct SoundRateLimiterTests {
	@Test("Plays at most the limit within one window")
	func capsWithinWindow() {
		var limiter = SoundRateLimiter(limit: 5, window: 60)
		var allowed: [Bool] = []
		for second in 0...5 {
			allowed.append(limiter.shouldPlay(at: referenceDate.addingTimeInterval(Double(second))))
		}

		#expect(allowed == [true, true, true, true, true, false])
	}

	@Test("Allows a sound again once the window has passed")
	func resetsAfterWindow() {
		var limiter = SoundRateLimiter(limit: 1, window: 60)
		let first = limiter.shouldPlay(at: referenceDate)
		let withinWindow = limiter.shouldPlay(at: referenceDate.addingTimeInterval(30))
		let afterWindow = limiter.shouldPlay(at: referenceDate.addingTimeInterval(60))

		#expect(first)
		#expect(withinWindow == false)
		#expect(afterWindow)
	}
}
