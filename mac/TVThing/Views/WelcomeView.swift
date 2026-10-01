import SwiftUI

/// First-run window: explains the setup and helps build a first lineup.
struct WelcomeView: View {
    @Environment(AppModel.self) private var model
    @State private var addingChannel = false
    let onFinish: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Welcome to TV Thing")
                        .font(.largeTitle.weight(.semibold))
                    Text("Turn your Car Thing into a tiny TV. The picture plays on the Car Thing while sound comes from your Mac.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    SetupChecklist()
                    Divider()
                    SetupInstructions()
                }
                .padding(6)
            } label: {
                Text("Connect your Car Thing")
                    .font(.headline)
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    Text(channelSummary)
                        .foregroundStyle(.secondary)
                    HStack {
                        Button("Add a Channel…") { addingChannel = true }
                        Button("Import Channel Pack…") {
                            if let url = FilePanels.chooseChannelFile() { model.importChannels(from: url) }
                        }
                        if model.library.channels.isEmpty {
                            Button("Add Starter Channels") { model.importStarterChannels() }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
            } label: {
                Text("Add channels")
                    .font(.headline)
            }

            HStack {
                Text("TV Thing lives in the menu bar. Look for the \(Image(systemName: "tv")) icon.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Done", action: onFinish)
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.large)
            }
        }
        .padding(24)
        .frame(width: 580)
        .sheet(isPresented: $addingChannel) {
            ChannelEditorView(mode: .add)
                .environment(model)
        }
    }

    private var channelSummary: String {
        let count = model.library.channels.count
        switch count {
        case 0: return "Add HLS streams (.m3u8), import a channel pack or M3U playlist, or start with some free channels."
        case 1: return "You have 1 channel. Add more any time from Settings."
        default: return "You have \(count) channels. The first four are on Car Thing buttons 1–4."
        }
    }
}
