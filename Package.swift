// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
	name: "CalendarShouter",
	defaultLocalization: "en",
	platforms: [
		.macOS(.v14)
	],
	products: [
		.executable(
			name: "CalendarShouter",
			targets: ["CalendarShouter"]
		)
	],
	dependencies: [],
	targets: [
		.plugin(
			name: "LocalizationPlugin",
			capability: .buildTool(),
			dependencies: [
				.target(name: "xcstrings-tool")
			]
		),
		.target(
			name: "CalendarShouterCore",
			resources: [
				.process("Resources")
			],
			plugins: [
				.plugin(name: "LocalizationPlugin")
			]
		),
		.executableTarget(
			name: "CalendarShouter",
			dependencies: [
				.target(name: "CalendarShouterCore")
			]
		),
		.testTarget(
			name: "CalendarShouterCoreTests",
			dependencies: [
				.target(name: "CalendarShouterCore")
			]
		),
		.binaryTarget(
			name: "xcstrings-tool",
			url:
				"https://github.com/liamnichols/xcstrings-tool/releases/download/1.2.0/xcstrings-tool.artifactbundle.zip",
			checksum: "6516a7d60181e222051c4ba925ec8d776390ffaa76789fd0a6f2f8a5fc364796"
		),
	]
)
