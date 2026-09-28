import Foundation
import PackagePlugin

/// Generates typed Swift accessors for the target's string catalogues, driving the
/// `xcstrings-tool` binary that the package declares as an artifact bundle.
///
/// This is a local replacement for the upstream `XCStringsToolPlugin`, kept in-tree
/// so that the inputs handed to the tool are ours to choose.
@main
struct LocalizationPlugin: BuildToolPlugin {
	func createBuildCommands(context: PluginContext, target: Target) async throws -> [Command] {
		guard let sourceModule = target.sourceModule else {
			Diagnostics.warning("LocalizationPlugin only supports source targets.")
			return []
		}

		let tables = sourceModule.sourceFiles.stringTables
		let tool = try context.tool(named: "xcstrings-tool").url
		let generatedDirectory = context.pluginWorkDirectoryURL.appending(path: "Generated")

		return tables.map { table in
			let output = generatedDirectory.appending(path: "\(table.name).swift")

			return .buildCommand(
				displayName: "LocalizationPlugin: Generate Swift code for '\(table.name)'",
				executable: tool,
				arguments: table.files.map { $0.url.path(percentEncoded: false) } + [
					"--output", output.path(percentEncoded: false),
					"--development-language", developmentLanguage,
				],
				inputFiles: table.files.map(\.url),
				outputFiles: [output]
			)
		}
	}

	/// Mirrors `defaultLocalization` in `Package.swift`.
	private var developmentLanguage: String { "en" }
}

private struct StringTable {
	let name: String
	let files: [File]
}

extension FileList {
	/// The target's string tables, one per `.strings` table name.
	///
	/// A catalogue wins over the `.lproj` files compiled from it: those live inside the
	/// target when a `localize` step has run, are not sources, and describing the same
	/// keys twice makes the tool fail with conflicting keys.
	fileprivate var stringTables: [StringTable] {
		let resources = filter { file in
			["xcstrings", "strings", "stringsdict"].contains(file.url.pathExtension)
		}

		return Dictionary(grouping: resources) { $0.url.deletingPathExtension().lastPathComponent }
			.map { name, files in
				let catalogues = files.filter { $0.url.pathExtension == "xcstrings" }
				guard catalogues.isEmpty else { return StringTable(name: name, files: catalogues) }
				return StringTable(name: name, files: files.filter(\.isDevelopmentLanguage))
			}
			.sorted { $0.name < $1.name }
	}
}

extension File {
	/// Whether this resource belongs to the development language's `.lproj` directory.
	fileprivate var isDevelopmentLanguage: Bool {
		let parent = url.deletingLastPathComponent().lastPathComponent
		return !parent.hasSuffix(".lproj") || parent == "en.lproj"
	}
}
