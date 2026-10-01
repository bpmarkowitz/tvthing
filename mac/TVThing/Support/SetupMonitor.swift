import AppKit
import Observation
import TVThingKit

/// Tracks everything TV Thing depends on, for the setup checklist.
@MainActor
@Observable
final class SetupMonitor {
    enum Check: Equatable {
        case ok(String)
        case pending(String)
        case problem(String)

        var isOK: Bool {
            if case .ok = self { return true }
            return false
        }
    }

    static let bridgethingBundleID = "com.bridgething.desktop"
    static let bridgethingURL = URL(string: "https://bridgething.com")!
    static let ffmpegInstallCommand = "brew install ffmpeg"

    private(set) var server: Check = .pending("Starting…")
    private(set) var bridgething: Check = .pending("Checking…")
    private(set) var carThing: Check = .pending("Waiting for TV Thing to open on the Car Thing")
    private(set) var ffmpeg: Check = .pending("Checking…")
    private(set) var ffmpegURL: URL?

    /// The packaged Car Thing webapp embedded in this build, if any.
    let carThingBundle = Bundle.main.url(forResource: "TVThing-CarThing", withExtension: "zip")

    var isReady: Bool { server.isOK && bridgething.isOK && carThing.isOK }

    private var timer: Task<Void, Never>?

    func start() {
        guard timer == nil else { return }
        timer = Task { [weak self] in
            while !Task.isCancelled {
                self?.refresh()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    func refresh() {
        let running = NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == Self.bridgethingBundleID }
        let installed = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bridgethingBundleID) != nil
        bridgething = running ? .ok("Running")
            : installed ? .problem("Installed but not running. Open Bridgething.")
            : .problem("Not installed")

        ffmpegURL = FFmpegLocator.locate(customPath: Preferences.ffmpegPath)
        ffmpeg = ffmpegURL.map { .ok($0.path) } ?? .problem("Not found. Only needed for some streams.")
    }

    func update(from snapshot: EngineSnapshot) {
        server = switch snapshot.server {
        case .starting: .pending("Starting…")
        case .ready: .ok("Listening on 127.0.0.1")
        case .failed(let message): .problem(message)
        }
        carThing = switch snapshot.device {
        case .connected(playing: true): .ok("Connected and playing")
        case .connected(playing: false): .ok("Connected")
        case .waiting: .pending("Open TV Thing on the Car Thing")
        }
    }

    func revealCarThingBundle() {
        guard let carThingBundle else { return }
        NSWorkspace.shared.activateFileViewerSelecting([carThingBundle])
    }

    func openBridgething() {
        if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bridgethingBundleID) {
            NSWorkspace.shared.openApplication(at: app, configuration: .init())
        } else {
            NSWorkspace.shared.open(Self.bridgethingURL)
        }
    }
}
