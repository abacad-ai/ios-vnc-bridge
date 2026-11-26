import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu-bar app: no Dock icon, no main window. The bundle's LSUIElement
        // says the same thing; this also covers `swift run` during development.
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppState.current?.stop()
    }
}

@main
struct IOSVNCBridgeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var state = AppState()

    var body: some Scene {
        MenuBarExtra {
            PanelView()
                .environmentObject(state)
        } label: {
            Image(systemName: state.status.isRunning ? "iphone.gen3.radiowaves.left.and.right" : "iphone")
        }
        .menuBarExtraStyle(.window)
    }
}
