import SwiftUI
import TVThingKit

struct PlaybackSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let audio = model.audio
        Form {
            Section {
                Toggle("Play audio on this Mac", isOn: Binding(get: { audio.isEnabled }, set: { model.setAudioEnabled($0) }))
                LabeledContent("Volume") {
                    Slider(value: Binding(get: { audio.volume }, set: { model.setVolume($0) }), in: 0...1) {
                        EmptyView()
                    } minimumValueLabel: {
                        Image(systemName: "speaker.fill")
                    } maximumValueLabel: {
                        Image(systemName: "speaker.wave.3.fill")
                    }
                }
                .disabled(!audio.isEnabled)
                LabeledContent("Audio delay") {
                    HStack {
                        OffsetControl()
                        Button("Re-sync Now") { model.audio.resync() }
                    }
                }
                .disabled(!audio.isEnabled)
                LabeledContent("Status", value: statusText)
            } header: {
                Text("Audio")
            } footer: {
                Text("The Car Thing shows the picture; sound plays through your Mac so its volume keys and speakers work. If lips and voices don't match, adjust the delay. A positive delay makes audio play later.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                @Bindable var model = model
                Toggle("CRT scanlines", isOn: $model.display.scanlines)
            } header: {
                Text("Car Thing Screen")
            } footer: {
                Text("Draws old-TV scanlines over the picture on the Car Thing.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("FFmpeg") {
                    HStack(spacing: 6) {
                        StatusDot(tone: model.setup.ffmpeg.tone)
                        Text(model.setup.ffmpegURL?.path ?? "Not found")
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
                LabeledContent("Custom location") {
                    HStack {
                        Text(model.ffmpegPath.isEmpty ? "Automatic" : model.ffmpegPath)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button("Choose…") {
                            if let url = FilePanels.chooseExecutable() {
                                model.ffmpegPath = url.path
                                model.setup.refresh()
                            }
                        }
                        if !model.ffmpegPath.isEmpty {
                            Button("Reset") {
                                model.ffmpegPath = ""
                                model.setup.refresh()
                            }
                        }
                    }
                }
                if model.setup.ffmpegURL == nil {
                    InstallCommandRow(command: SetupMonitor.ffmpegInstallCommand)
                }
            } header: {
                Text("Stream Conversion")
            } footer: {
                Text("Most streams play directly. Streams the Car Thing can't decode, or that lack the timestamps used to sync audio, are converted with FFmpeg, which is free but installed separately.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var statusText: String {
        let audio = model.audio
        if audio.status == .playing, let difference = audio.differenceMs {
            return "In sync (measured \(difference) ms)"
        }
        return audio.status.label
    }
}

/// Shows a shell command with a copy button.
struct InstallCommandRow: View {
    let command: String
    @State private var copied = false

    var body: some View {
        LabeledContent("Install with Homebrew") {
            HStack {
                Text(command)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                Button(copied ? "Copied" : "Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(command, forType: .string)
                    copied = true
                }
            }
        }
    }
}
