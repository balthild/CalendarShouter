import Foundation

/// A selectable reminder sound.
public enum SoundChoice: Sendable, Identifiable, Hashable {
	/// Play nothing.
	case none
	/// A sound found on disk, identified by its name without a file extension.
	case system(name: String)

	public var id: String {
		switch self {
		case .none: ""
		case .system(let name): name
		}
	}

	/// The value persisted in `SettingsStore.soundName`.
	public var soundName: String { id }

	public static func from(soundName: String) -> SoundChoice {
		soundName.isEmpty ? .none : .system(name: soundName)
	}
}

/// The sounds offered in the settings window.
public struct SoundCatalog: Sendable {
	/// Directories searched for system and user sounds, in order.
	public static var defaultSearchDirectories: [URL] {
		let home = FileManager.default.homeDirectoryForCurrentUser
		return [
			URL(fileURLWithPath: "/System/Library/Sounds", isDirectory: true),
			home.appendingPathComponent("Library/Sounds", isDirectory: true),
		]
	}

	public let choices: [SoundChoice]

	/// Creates a catalog by scanning `directories` for sound files.
	///
	/// The list follows `directories` order — sorted within each of them, so the user's own
	/// sounds come after the system's — and a name found in more than one directory is
	/// listed once, under the earlier directory.
	public init(directories: [URL] = SoundCatalog.defaultSearchDirectories) {
		let fileManager = FileManager.default
		var seen: Set<String> = []
		var namesByDirectory: [[String]] = []

		for directory in directories {
			let contents =
				(try? fileManager.contentsOfDirectory(
					at: directory,
					includingPropertiesForKeys: nil,
					options: [.skipsHiddenFiles]
				)) ?? []
			let names =
				contents
				.filter { Self.soundFileExtensions.contains($0.pathExtension.lowercased()) }
				.map { $0.deletingPathExtension().lastPathComponent }
				.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
				.filter { seen.insert($0).inserted }
			namesByDirectory.append(names)
		}

		choices = [.none] + namesByDirectory.joined().map(SoundChoice.system(name:))
	}

	private static let soundFileExtensions: Set<String> = ["aiff", "aif", "wav", "m4a", "caf", "mp3"]
}
