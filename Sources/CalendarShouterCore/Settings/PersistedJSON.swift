import Foundation

/// Encoding for the values the app keeps in `UserDefaults`.
///
/// A value is stored as the property-list object its JSON describes — a dictionary or an array
/// rather than an opaque `Data` blob — so `defaults read` shows the fields. Two shapes stay as
/// JSON text: a value written by an earlier version, which was always text, and one containing a
/// JSON null, which `UserDefaults` refuses to hold. Both read back the same either way.
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
		defaults.set(plistObject(from: data) ?? data, forKey: key)
	}

	static func value<T: Decodable>(
		_ type: T.Type,
		forKey key: String,
		in defaults: UserDefaults
	) -> T? {
		guard let stored = defaults.object(forKey: key) else { return nil }

		if let data = jsonData(from: stored),
			let decoded = try? JSONDecoder().decode(type, from: data)
		{
			return decoded
		}

		// Left in place as well as copied: the stored value is not the app's to destroy,
		// and re-quarantining on the next launch is prevented by the guard below. The copy is
		// the text form because that is storable whatever the original was.
		let quarantine = quarantineKey(for: key)
		if defaults.object(forKey: quarantine) == nil, let data = jsonData(from: stored) {
			defaults.set(data, forKey: quarantine)
		}
		return nil
	}

	/// The JSON text behind a stored value.
	///
	/// `Data` is what an earlier version wrote; anything else is the property-list object.
	private static func jsonData(from stored: Any) -> Data? {
		if let data = stored as? Data { return data }
		return try? JSONSerialization.data(withJSONObject: stored, options: [.fragmentsAllowed])
	}

	/// The JSON object represented by the given data, or nil if it cannot be decoded.
	///
	/// `Data` is the raw JSON text encoded from the original value.
	private static func jsonObject(from data: Data) -> Any? {
		return try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
	}

	/// The property-list object JSON text describes, or nil when `UserDefaults` cannot hold it.
	///
	/// A JSON null decodes to `NSNull`, and `UserDefaults` rejects that by aborting the process
	/// rather than reporting an error, so a value containing one has to stay as text.
	private static func plistObject(from data: Data) -> Any? {
		guard let object = jsonObject(from: data), !containsNull(object) else { return nil }
		return object
	}

	private static func containsNull(_ value: Any) -> Bool {
		if value is NSNull { return true }
		if let dictionary = value as? [String: Any] {
			return dictionary.values.contains(where: containsNull)
		}
		if let array = value as? [Any] {
			return array.contains(where: containsNull)
		}
		return false
	}
}
