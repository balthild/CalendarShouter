import AppKit

/// Plays the sound configured for reminders.
@MainActor
public final class SoundPlayer {
	private var currentSound: NSSound?

	public init() {}

	/// Plays the named system sound, or does nothing for an empty name.
	public func play(soundName: String) {
		guard !soundName.isEmpty else { return }
		currentSound?.stop()
		guard let sound = NSSound(named: soundName) else { return }
		currentSound = sound
		sound.play()
	}
}
