import SwiftUI
import TVThingKit

/// Adds a channel or edits one. The source is validated through the provider registry
/// before it can be saved.
struct ChannelEditorView: View {
    enum Mode: Identifiable {
        case add
        case edit(Channel)

        var id: String {
            switch self {
            case .add: "add"
            case .edit(let channel): channel.id.uuidString
            }
        }
    }

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let mode: Mode

    @State private var input = ""
    @State private var name = ""
    @State private var playback = PlaybackMode.automatic
    @State private var favoriteSlot: Int?
    /// The last successful lookup, valid only while the text field still matches it.
    @State private var confirmed: (input: String, source: SourceReference)?
    @State private var lookup: Task<Void, Never>?
    @State private var lookupError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(isEditing ? "Edit Channel" : "Add Channel")
                .font(.title3.weight(.semibold))
                .padding([.horizontal, .top], 20)
                .padding(.bottom, 8)

            Form {
                Section {
                    HStack {
                        TextField("Stream", text: $input, prompt: Text("https://…/stream.m3u8 or a tuner URL"))
                            .onSubmit(lookUp)
                            .onChange(of: input) { lookupError = nil }
                        if lookup != nil {
                            ProgressView().controlSize(.small)
                        } else {
                            Button("Look Up", action: lookUp)
                                .disabled(trimmedInput.isEmpty || source != nil)
                        }
                    }
                    sourceStatus
                }

                Section {
                    TextField("Name", text: $name, prompt: Text("Channel name"))
                    Picker("Car Thing button", selection: $favoriteSlot) {
                        Text("None").tag(Int?.none)
                        ForEach(0..<ChannelLibrary.favoriteSlotCount, id: \.self) { slot in
                            Text(buttonTitle(slot)).tag(Int?.some(slot))
                        }
                    }
                    Picker("Playback", selection: $playback) {
                        Text("Automatic").tag(PlaybackMode.automatic)
                        Text("Always direct").tag(PlaybackMode.direct)
                        Text("Always convert with FFmpeg").tag(PlaybackMode.convert)
                    }
                } footer: {
                    Text("Automatic plays streams directly when the Car Thing can handle them and converts the rest with FFmpeg.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isEditing ? "Save" : "Add Channel", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(source == nil || name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(20)
        }
        .frame(width: 500)
        .onAppear(perform: load)
        .onDisappear { lookup?.cancel() }
    }

    @ViewBuilder
    private var sourceStatus: some View {
        if let lookupError {
            Label(lookupError, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.red)
        } else if let source {
            Label(model.registry.summary(of: source), systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        } else {
            Text("Paste an HLS playlist URL (.m3u8) or a broadcast stream URL (such as an HDHomeRun channel), then press Return.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var trimmedInput: String {
        input.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var source: SourceReference? {
        confirmed?.input == trimmedInput ? confirmed?.source : nil
    }

    private var isEditing: Bool {
        if case .edit = mode { return true }
        return false
    }

    private func buttonTitle(_ slot: Int) -> String {
        guard let occupant = model.library.favorite(at: slot), occupant.id != editingID else { return "Button \(slot + 1)" }
        return "Button \(slot + 1) (replaces \(occupant.name))"
    }

    private var editingID: Channel.ID? {
        if case .edit(let channel) = mode { return channel.id }
        return nil
    }

    private func load() {
        guard case .edit(let channel) = mode else { return }
        input = channel.source.value
        name = channel.name
        playback = channel.playback
        favoriteSlot = model.library.favoriteSlot(of: channel.id)
        confirmed = (channel.source.value, channel.source)
    }

    private func lookUp() {
        let text = trimmedInput
        guard !text.isEmpty, lookup == nil, source == nil else { return }
        lookupError = nil
        lookup = Task {
            defer { lookup = nil }
            do {
                let candidate = try await model.registry.candidate(for: text)
                guard !Task.isCancelled else { return }
                confirmed = (text, candidate.reference)
                if name.trimmingCharacters(in: .whitespaces).isEmpty, let suggestion = candidate.suggestedName {
                    name = suggestion
                }
            } catch {
                lookupError = error.localizedDescription
            }
        }
    }

    private func save() {
        guard let source else { return }
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        switch mode {
        case .add:
            model.add(Channel(name: trimmedName, source: source, playback: playback), favoriteSlot: favoriteSlot)
        case .edit(var channel):
            channel.name = trimmedName
            channel.source = source
            channel.playback = playback
            model.update(channel, favoriteSlot: favoriteSlot)
        }
        dismiss()
    }
}
