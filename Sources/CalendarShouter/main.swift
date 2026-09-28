import AppKit
import CalendarShouterCore

// The application uses AppKit's lifecycle so that the status item, the
// settings window and the reminder panels can all be controlled directly.
// All view content is SwiftUI hosted inside those AppKit containers.
let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.run()
