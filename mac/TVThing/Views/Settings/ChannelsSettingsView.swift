import SwiftUI
import TVThingKit

struct ChannelsSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var selection = Set<Channel.ID>()
    @State private var editor: ChannelEditorView.Mode?

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            if model.library.channels.isEmpty {
                ContentUnavailableView {
                    Label("No Channels", systemImage: "tv")
                } description: {
                    Text("Add any HLS stream (.m3u8), import a channel pack or M3U playlist, or start with a few free test channels.")
                } actions: {
                    Button("Add Channel…") { editor = .add }
                    Button("Import…") { importChannels() }
                    Button("Add Starter Channels") { model.importStarterChannels() }
                }
            } else {
                channelList
            }
            Divider()
            toolbar
        }
        .sheet(item: $editor) { mode in
            ChannelEditorView(mode: mode)
        }
        .alert("Something went wrong", isPresented: Binding(get: { model.alert != nil }, set: { if !$0 { model.alert = nil } })) {
            Button("OK") { model.alert = nil }
        } message: {
            Text(model.alert ?? "")
        }
        .alert("Channels Imported", isPresented: Binding(get: { model.importNotice != nil }, set: { if !$0 { model.importNotice = nil } })) {
            Button("OK") { model.importNotice = nil }
        } message: {
            Text(model.importNotice ?? "")
        }
    }

    private var channelList: some View {
        let library = model.library
        return List(selection: $selection) {
            ForEach(Array(library.channels.enumerated()), id: \.element.id) { index, channel in
                ChannelRow(number: index + 1, channel: channel, favoriteSlot: library.favoriteSlot(of: channel.id), isCurrent: channel.id == library.currentChannelID)
                    .tag(channel.id)
            }
            .onMove { model.move(fromOffsets: $0, toOffset: $1) }
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
        .contextMenu(forSelectionType: Channel.ID.self) { ids in
            if ids.count == 1, let id = ids.first, let channel = library.channel(withID: id) {
                Button("Tune In") { model.tune(.channel(id)) }
                Button("Edit…") { editor = .edit(channel) }
                Menu("Car Thing Button") {
                    ForEach(0..<ChannelLibrary.favoriteSlotCount, id: \.self) { slot in
                        Button("Button \(slot + 1)\(library.favorite(at: slot).map { " (replaces \($0.name))" } ?? "")") {
                            model.setFavorite(id, slot: slot)
                        }
                    }
                    if let slot = library.favoriteSlot(of: id) {
                        Divider()
                        Button("Remove from Button \(slot + 1)") { model.setFavorite(nil, slot: slot) }
                    }
                }
                Divider()
            }
            if !ids.isEmpty {
                Button("Export…") { exportChannels(ids) }
                Button("Delete", role: .destructive) { model.remove(ids) }
            }
        } primaryAction: { ids in
            if ids.count == 1, let id = ids.first, let channel = library.channel(withID: id) {
                editor = .edit(channel)
            }
        }
        .onDeleteCommand { model.remove(selection) }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            ControlGroup {
                Button { editor = .add } label: { Image(systemName: "plus") }
                    .help("Add a channel")
                Button { model.remove(selection); selection.removeAll() } label: { Image(systemName: "minus") }
                    .disabled(selection.isEmpty)
                    .help("Delete the selected channels")
            }
            .fixedSize()
            Text("Drag to reorder. Right-click to assign a Car Thing button.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Import…") { importChannels() }
            Menu("Export") {
                Button("All Channels…") { exportChannels(nil) }
                Button("Selected Channels…") { exportChannels(selection) }
                    .disabled(selection.isEmpty)
            }
            .fixedSize()
            .disabled(model.library.channels.isEmpty)
        }
        .padding(10)
    }

    private func importChannels() {
        if let url = FilePanels.chooseChannelFile() { model.importChannels(from: url) }
    }

    private func exportChannels(_ ids: Set<Channel.ID>?) {
        if let url = FilePanels.chooseExportDestination() { model.exportChannels(to: url, ids: ids) }
    }
}

private struct ChannelRow: View {
    @Environment(AppModel.self) private var model
    let number: Int
    let channel: Channel
    let favoriteSlot: Int?
    let isCurrent: Bool

    var body: some View {
        HStack(spacing: 10) {
            Text("\(number)")
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 28, alignment: .trailing)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(channel.name)
                    if isCurrent {
                        Image(systemName: "dot.radiowaves.left.and.right")
                            .font(.caption)
                            .foregroundStyle(Color.accentColor)
                            .help("On air")
                    }
                }
                Text(model.registry.summary(of: channel.source) + playbackNote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            if let favoriteSlot { FavoriteBadge(slot: favoriteSlot) }
        }
        .padding(.vertical, 2)
    }

    private var playbackNote: String {
        switch channel.playback {
        case .automatic: ""
        case .direct: " · Always direct"
        case .convert: " · Always convert"
        }
    }
}
