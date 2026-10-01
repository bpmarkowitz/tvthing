import SwiftUI
import TVThingKit

/// The window shown from the menu bar: what's on, favorites, the lineup, and audio.
struct MenuBarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            NowPlayingHeader()
                .padding(12)
            Divider()
            if model.library.channels.isEmpty {
                EmptyLineupView()
                    .padding(16)
            } else {
                FavoritesRow()
                    .padding(.horizontal, 10)
                    .padding(.vertical, 10)
                Divider()
                ChannelListView()
            }
            Divider()
            AudioControls()
                .padding(12)
            Divider()
            MenuFooter()
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
        }
        .frame(width: 330)
    }
}

// MARK: - Now playing

private struct NowPlayingHeader: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let library = model.library
        HStack(spacing: 12) {
            ChannelNumberTile(
                number: library.currentChannelID.flatMap(library.number(of:)),
                size: 44,
                isLive: model.snapshot.device.isConnected
            )
            VStack(alignment: .leading, spacing: 3) {
                Text(model.currentChannel?.name ?? "No channel")
                    .font(.headline)
                    .lineLimit(1)
                Text(statusLine)
                    .font(.caption)
                    .foregroundStyle(isProblem ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                    .lineLimit(2)
                    .help(statusLine)
            }
            Spacer(minLength: 0)
            if model.currentChannel != nil {
                Button {
                    model.restartStream()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Restart the stream")
            }
        }
    }

    private var isProblem: Bool {
        if case .failed = model.snapshot.phase { return true }
        if case .failed = model.snapshot.server { return true }
        return false
    }

    private var statusLine: String {
        let snapshot = model.snapshot
        if case .failed(let message) = snapshot.server { return message }
        guard model.currentChannel != nil else { return "Add a channel to get started" }
        guard snapshot.device.isConnected else { return "Waiting for the Car Thing" }
        switch snapshot.phase {
        case nil, .preparing: return "Tuning…"
        case .failed(let message): return message
        case .playing(let delivery):
            let playing = snapshot.device == .connected(playing: true) ? "On air" : "Buffering"
            return "\(playing) · \(delivery.label)"
        }
    }
}

// MARK: - Favorites

private struct FavoritesRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<ChannelLibrary.favoriteSlotCount, id: \.self) { slot in
                FavoriteButton(slot: slot)
            }
        }
    }
}

private struct FavoriteButton: View {
    @Environment(AppModel.self) private var model
    let slot: Int

    var body: some View {
        let channel = model.library.favorite(at: slot)
        let isCurrent = channel != nil && channel?.id == model.library.currentChannelID
        Button {
            model.tune(.favorite(slot))
        } label: {
            VStack(spacing: 2) {
                Text("\(slot + 1)")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(isCurrent ? AnyShapeStyle(.white.opacity(0.85)) : AnyShapeStyle(.tertiary))
                Text(channel?.name ?? "Empty")
                    .font(.caption)
                    .lineLimit(1)
                    .foregroundStyle(isCurrent ? AnyShapeStyle(.white) : channel == nil ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 4)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isCurrent ? AnyShapeStyle(Color.accentColor.gradient) : AnyShapeStyle(.quinary))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(channel == nil)
        .help(channel.map { "Button \(slot + 1): \($0.name)" } ?? "Button \(slot + 1) is empty. Right-click to assign the current channel.")
        .contextMenu {
            if let current = model.currentChannel {
                Button("Assign “\(current.name)”") { model.setFavorite(current.id, slot: slot) }
            }
            if channel != nil {
                Button("Clear") { model.setFavorite(nil, slot: slot) }
            }
        }
    }
}

// MARK: - Channel list

private struct ChannelListView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let library = model.library
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(Array(library.channels.enumerated()), id: \.element.id) { index, channel in
                        Button {
                            model.tune(.channel(channel.id))
                        } label: {
                            HStack(spacing: 10) {
                                Text("\(index + 1)")
                                    .font(.callout.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                    .frame(width: 26, alignment: .trailing)
                                Text(channel.name)
                                    .lineLimit(1)
                                Spacer(minLength: 4)
                                if let slot = library.favoriteSlot(of: channel.id) {
                                    FavoriteBadge(slot: slot)
                                }
                            }
                        }
                        .buttonStyle(MenuRowButtonStyle(isSelected: channel.id == library.currentChannelID))
                        .id(channel.id)
                    }
                }
                .padding(6)
            }
            .frame(height: min(CGFloat(library.channels.count) * 27 + 12, 250))
            .onAppear {
                if let id = library.currentChannelID { proxy.scrollTo(id, anchor: .center) }
            }
        }
    }
}

private struct EmptyLineupView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "tv.badge.wifi")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text("No channels yet")
                .font(.headline)
            Text("Add a stream URL or import a channel pack in Settings.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Add Channels…") { model.openSettings(.channels) }
                .controlSize(.small)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Audio

private struct AudioControls: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let audio = model.audio
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    model.toggleMute()
                } label: {
                    Image(systemName: audio.isMuted || !audio.isEnabled ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .frame(width: 18)
                }
                .buttonStyle(.borderless)
                .disabled(!audio.isEnabled)
                .help(audio.isMuted ? "Unmute (the picture keeps playing)" : "Mute (the picture keeps playing)")

                Slider(value: Binding(get: { audio.volume }, set: { model.setVolume($0) }), in: 0...1)
                    .controlSize(.small)
                    .disabled(!audio.isEnabled)
            }
            HStack(spacing: 6) {
                Text(syncLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text("Delay")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                OffsetControl()
            }
            .disabled(!audio.isEnabled)
        }
    }

    private var syncLabel: String {
        let audio = model.audio
        if audio.status == .playing, let difference = audio.differenceMs {
            return "In sync (\(difference > 0 ? "+" : "")\(difference) ms)"
        }
        return audio.status.label
    }
}

/// Nudges the audio delay in 50 ms steps; clicking the value resets it.
struct OffsetControl: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 2) {
            Button { model.adjustOffset(by: -50) } label: { Image(systemName: "minus") }
            Button { model.setOffset(0) } label: {
                Text("\(model.audio.offsetMs) ms")
                    .font(.caption.monospacedDigit())
                    .frame(minWidth: 52)
            }
            .help("Audio delay relative to the picture. Click to reset.")
            Button { model.adjustOffset(by: 50) } label: { Image(systemName: "plus") }
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
    }
}

// MARK: - Footer

private struct MenuFooter: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 5) {
                StatusDot(tone: model.setup.carThing.tone)
                Text(model.snapshot.device.isConnected ? "Car Thing" : "Car Thing not connected")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .help(model.setup.carThing.detail)
            Spacer()
            Button {
                model.openSettings(nil)
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .help("Settings")
            Button {
                NSApp.terminate(nil)
            } label: {
                Image(systemName: "power")
            }
            .buttonStyle(.borderless)
            .help("Quit TV Thing")
        }
    }
}
