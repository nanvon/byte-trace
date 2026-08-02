import AppKit
import Foundation
import SwiftUI

@MainActor
final class IconLabAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)

        guard let outputRoot = commandLineOutputRoot else { return }
        do {
            let output = try IconExporter.exportAll(
                spec: .appIcon,
                menuBarSpec: .menuBar,
                outputRoot: outputRoot
            )
            print("[iconlab] exported " + output.path)
        } catch {
            fputs("[iconlab] export failed: \(error.localizedDescription)\n", stderr)
        }
        NSApplication.shared.terminate(nil)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    private var commandLineOutputRoot: URL? {
        guard let flagIndex = CommandLine.arguments.firstIndex(of: "--export-to"),
              flagIndex + 1 < CommandLine.arguments.count else {
            return nil
        }
        return URL(
            fileURLWithPath: CommandLine.arguments[flagIndex + 1],
            isDirectory: true
        )
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
