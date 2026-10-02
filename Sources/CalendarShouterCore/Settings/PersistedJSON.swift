import Foundation

/// JSON encoding for the values the app keeps in `UserDefaults`.
///
/// A value that no longer decodes is copied aside instead of being dropped. Failing quietly
/// is the worse outcome: the array-shaped values are decoded whole, so a single unreadable
/// record would otherwise empty the entire list, and the next write would make that loss
/// permanent.
enum PersistedJSON {
	/// Appended to a key whose value failed to decode.
	///
	/// Nothing reads this back. It exists so that a schema mistake costs the user a
	/// reconfiguration rather than the data itself.
	static func quarantineKey(for key: String) -> String { "\(key).unreadable" }

	static func set<T: Encodable>(_ value: T, forKey key: String, in defaults: UserDefaults) {
		guard let data = try? JSONEncoder().encode(value) else { return }
		defaults.set(data, forKey: key)
	}

	static func value<T: Decodable>(
		_ type: T.Type,
		forKey key: String,
		in defaults: UserDefaults
	) -> T? {
		guard let data = defaults.data(forKey: key) else { return nil }
		if let decoded = try? JSONDecoder().decode(type, from: data) { return decoded }

		// Left in place as well as copied: the stored value is not the app's to destroy,
		// and re-quarantining on the next launch is prevented by the guard below.
		let quarantine = quarantineKey(for: key)
		if defaults.data(forKey: quarantine) == nil {
			defaults.set(data, forKey: quarantine)
		}
		return nil
	}
}
