import AppKit
import SwiftUI

@MainActor
final class IconLabAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

@main
struct ByteTraceIconLab: App {
    @NSApplicationDelegateAdaptor(IconLabAppDelegate.self)
    private var appDelegate

    var body: some Scene {
        Window("ByteTrace Icon Lab", id: "iconlab") {
            IconLabView()
        }
        .defaultSize(width: 960, height: 680)
    }
}
