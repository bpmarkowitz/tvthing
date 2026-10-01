import AppKit
import TVThingKit
import UniformTypeIdentifiers

@MainActor
enum FilePanels {
    private static var channelFileTypes: [UTType] {
        [UTType(filenameExtension: ChannelPack.fileExtension), .json, UTType(filenameExtension: "m3u"), UTType(filenameExtension: "m3u8")]
            .compactMap { $0 }
    }

    static func chooseChannelFile() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Import Channels"
        panel.message = "Choose a TV Thing channel pack or an M3U playlist."
        panel.allowedContentTypes = channelFileTypes
        panel.allowsMultipleSelection = false
        return run(panel)
    }

    static func chooseExportDestination() -> URL? {
        let panel = NSSavePanel()
        panel.title = "Export Channels"
        panel.nameFieldStringValue = "My Channels.\(ChannelPack.fileExtension)"
        panel.allowedContentTypes = channelFileTypes.prefix(1).map { $0 }
        return run(panel)
    }

    static func chooseExecutable() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Choose FFmpeg"
        panel.message = "Select the ffmpeg executable."
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/opt/homebrew/bin")
        panel.showsHiddenFiles = true
        return run(panel)
    }

    private static func run(_ panel: NSSavePanel) -> URL? {
        NSApp.activate(ignoringOtherApps: true)
        return panel.runModal() == .OK ? panel.url : nil
    }
}
