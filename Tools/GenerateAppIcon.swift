#!/usr/bin/env swift
//
// Generates the CalendarShouter app icon as a macOS `.iconset` directory.
//
// Usage: swift Tools/GenerateAppIcon.swift <output.iconset>
//
// If `App/Resources/AppIcon-1024.png` exists it is used as the source artwork
// and downscaled; otherwise the icon is drawn programmatically so that the
// repository needs no binary assets.

import AppKit
import Foundation

private let outputPath =
	CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset"
private let masterImagePath = "App/Resources/AppIcon-1024.png"

private let variants: [(name: String, pixelSize: Int)] = [
	("icon_16x16", 16),
	("icon_16x16@2x", 32),
	("icon_32x32", 32),
	("icon_32x32@2x", 64),
	("icon_128x128", 128),
	("icon_128x128@2x", 256),
	("icon_256x256", 256),
	("icon_256x256@2x", 512),
	("icon_512x512", 512),
	("icon_512x512@2x", 1024),
]

/// Draws the icon into the current graphics context using unit coordinates
/// (0...1), so a single description serves every pixel size.
private func drawIcon() {
	guard let context = NSGraphicsContext.current?.cgContext else { return }

	let margin: CGFloat = 0.085
	let body = CGRect(x: margin, y: margin, width: 1 - margin * 2, height: 1 - margin * 2)
	let bodyRadius = body.width * 0.2237
	let bodyPath = CGPath(
		roundedRect: body,
		cornerWidth: bodyRadius,
		cornerHeight: bodyRadius,
		transform: nil
	)

	// Background: a blue gradient squircle.
	context.saveGState()
	context.addPath(bodyPath)
	context.clip()
	let background = NSGradient(colors: [
		NSColor(srgbRed: 0.38, green: 0.57, blue: 0.99, alpha: 1),
		NSColor(srgbRed: 0.15, green: 0.30, blue: 0.84, alpha: 1),
	])
	background?.draw(in: body, angle: -90)
	context.restoreGState()

	// Calendar page.
	let page = CGRect(
		x: body.minX + body.width * 0.17,
		y: body.minY + body.height * 0.15,
		width: body.width * 0.66,
		height: body.height * 0.62
	)
	let pageRadius = page.width * 0.12
	let pagePath = CGPath(
		roundedRect: page,
		cornerWidth: pageRadius,
		cornerHeight: pageRadius,
		transform: nil
	)

	context.saveGState()
	context.addPath(pagePath)
	context.setFillColor(NSColor.white.cgColor)
	context.fillPath()
	context.restoreGState()

	// Red header strip, clipped to the page's rounded corners.
	context.saveGState()
	context.addPath(pagePath)
	context.clip()
	let headerHeight = page.height * 0.28
	context.setFillColor(NSColor(srgbRed: 0.98, green: 0.33, blue: 0.33, alpha: 1).cgColor)
	context.fill(
		CGRect(
			x: page.minX,
			y: page.maxY - headerHeight,
			width: page.width,
			height: headerHeight
		)
	)
	context.restoreGState()

	// Two "entry" lines beneath the header.
	let lineHeight = page.height * 0.075
	let lineRadius = lineHeight / 2
	let lineColor = NSColor(srgbRed: 0.65, green: 0.69, blue: 0.77, alpha: 1).cgColor
	let lines = [
		CGRect(
			x: page.minX + page.width * 0.14,
			y: page.minY + page.height * 0.32,
			width: page.width * 0.72,
			height: lineHeight
		),
		CGRect(
			x: page.minX + page.width * 0.14,
			y: page.minY + page.height * 0.14,
			width: page.width * 0.46,
			height: lineHeight
		),
	]
	context.setFillColor(lineColor)
	for line in lines {
		context.addPath(
			CGPath(
				roundedRect: line,
				cornerWidth: lineRadius,
				cornerHeight: lineRadius,
				transform: nil
			)
		)
		context.fillPath()
	}

	// Notification badge.
	let badgeDiameter = body.width * 0.36
	let badge = CGRect(
		x: body.maxX - badgeDiameter - body.width * 0.02,
		y: body.minY + body.height * 0.02,
		width: badgeDiameter,
		height: badgeDiameter
	)
	context.saveGState()
	context.setShadow(
		offset: CGSize(width: 0, height: -0.012),
		blur: 0.03,
		color: NSColor.black.withAlphaComponent(0.25).cgColor
	)
	context.setFillColor(NSColor.white.cgColor)
	context.fillEllipse(in: badge)
	context.restoreGState()

	// Exclamation mark inside the badge.
	let barWidth = badgeDiameter * 0.15
	context.setFillColor(NSColor(srgbRed: 0.96, green: 0.27, blue: 0.27, alpha: 1).cgColor)
	context.addPath(
		CGPath(
			roundedRect: CGRect(
				x: badge.midX - barWidth / 2,
				y: badge.minY + badgeDiameter * 0.33,
				width: barWidth,
				height: badgeDiameter * 0.37
			),
			cornerWidth: barWidth / 2,
			cornerHeight: barWidth / 2,
			transform: nil
		)
	)
	context.fillPath()
	let dotDiameter = badgeDiameter * 0.16
	context.fillEllipse(
		in: CGRect(
			x: badge.midX - dotDiameter / 2,
			y: badge.minY + badgeDiameter * 0.17,
			width: dotDiameter,
			height: dotDiameter
		)
	)
}

private func makeBitmap(pixelSize: Int, draw: () -> Void) -> NSBitmapImageRep? {
	guard
		let representation = NSBitmapImageRep(
			bitmapDataPlanes: nil,
			pixelsWide: pixelSize,
			pixelsHigh: pixelSize,
			bitsPerSample: 8,
			samplesPerPixel: 4,
			hasAlpha: true,
			isPlanar: false,
			colorSpaceName: .deviceRGB,
			bytesPerRow: 0,
			bitsPerPixel: 0
		), let context = NSGraphicsContext(bitmapImageRep: representation)
	else { return nil }

	NSGraphicsContext.saveGraphicsState()
	NSGraphicsContext.current = context
	context.imageInterpolation = .high
	context.cgContext.scaleBy(x: CGFloat(pixelSize), y: CGFloat(pixelSize))
	draw()
	NSGraphicsContext.restoreGraphicsState()
	return representation
}

private func pngData(forPixelSize pixelSize: Int, master: NSImage?) -> Data? {
	let representation: NSBitmapImageRep?
	if let master {
		representation = makeBitmap(pixelSize: pixelSize) {
			master.draw(
				in: NSRect(x: 0, y: 0, width: 1, height: 1),
				from: .zero,
				operation: .copy,
				fraction: 1
			)
		}
	} else {
		representation = makeBitmap(pixelSize: pixelSize, draw: drawIcon)
	}
	return representation?.representation(using: .png, properties: [:])
}

private func generate() throws {
	let outputURL = URL(fileURLWithPath: outputPath)
	let fileManager = FileManager.default
	try? fileManager.removeItem(at: outputURL)
	try fileManager.createDirectory(at: outputURL, withIntermediateDirectories: true)

	let master = NSImage(contentsOfFile: masterImagePath)
	if master == nil {
		print("note: \(masterImagePath) not found; drawing the icon programmatically.")
	}

	var cache: [Int: Data] = [:]
	for variant in variants {
		let data: Data
		if let cached = cache[variant.pixelSize] {
			data = cached
		} else {
			guard let generated = pngData(forPixelSize: variant.pixelSize, master: master) else {
				throw IconError.renderFailed(variant.name)
			}
			data = generated
			cache[variant.pixelSize] = generated
		}
		try data.write(to: outputURL.appendingPathComponent("\(variant.name).png"))
	}

	print("Generated \(variants.count) images in \(outputPath)")
}

private enum IconError: Error, CustomStringConvertible {
	case renderFailed(String)

	var description: String {
		switch self {
		case .renderFailed(let name): "Failed to render \(name).png"
		}
	}
}

do {
	try generate()
} catch {
	FileHandle.standardError.write(Data("error: \(error)\n".utf8))
	exit(1)
}
