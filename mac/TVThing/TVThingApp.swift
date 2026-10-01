import AppKit
import SwiftUI

@main
struct TVThingApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environment(appDelegate.model)
        } label: {
            MenuBarLabel(model: appDelegate.model)
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    private var welcomeWindow: NSWindow?
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        model.openSettings = { [weak self] tab in self?.showSettings(tab) }
        if !Preferences.hasCompletedSetup { showWelcome() }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Stop FFmpeg and release the port before exiting.
        Task {
            await model.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// A sidebar-style Settings window with a hidden title, like Tabulate's.
    func showSettings(_ tab: SettingsTab? = nil) {
        if let tab { UserDefaults.standard.set(tab.rawValue, forKey: "SelectedSettingsTab") }
        if settingsWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 760, height: 500),
                styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.title = "TV Thing Settings"
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.isReleasedWhenClosed = false
            window.contentViewController = NSHostingController(rootView: SettingsView().environment(model))
            window.setContentSize(NSSize(width: 760, height: 500))
            window.contentMinSize = NSSize(width: 640, height: 420)
            window.setFrameAutosaveName("SettingsWindow")
            window.center()
            settingsWindow = window
        }
        // TV Thing has no Dock icon, so bring the window to the front explicitly.
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    func showWelcome() {
        if welcomeWindow == nil {
            let view = WelcomeView { [weak self] in
                Preferences.hasCompletedSetup = true
                self?.welcomeWindow?.close()
            }
            .environment(model)
            let window = NSWindow(contentViewController: NSHostingController(rootView: view))
            window.title = "Welcome to TV Thing"
            window.styleMask = [.titled, .closable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.isReleasedWhenClosed = false
            window.center()
            welcomeWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        welcomeWindow?.makeKeyAndOrderFront(nil)
    }
}

/// The menu bar icon: a TV, filled while the Car Thing is connected, plus the channel number.
struct MenuBarLabel: View {
    let model: AppModel

    var body: some View {
        let connected = model.snapshot.device.isConnected
        HStack(spacing: 3) {
            Image(systemName: connected ? "tv.fill" : "tv")
            if let id = model.library.currentChannelID, let number = model.library.number(of: id) {
                Text("\(number)").monospacedDigit()
            }
        }
        .accessibilityLabel(connected ? "TV Thing, connected" : "TV Thing")
    }
}
