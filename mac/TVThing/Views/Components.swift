import SwiftUI
import TVThingKit

/// A channel number in a small rounded tile, like a set-top box display.
struct ChannelNumberTile: View {
    let number: Int?
    var size: CGFloat = 38
    var isLive = false

    var body: some View {
        Text(number.map(String.init) ?? "–")
            .font(.system(size: size * 0.45, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .minimumScaleFactor(0.5)
            .lineLimit(1)
            .frame(width: size, height: size)
            .foregroundStyle(isLive ? Color.white : Color.primary)
            .background(
                RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                    .fill(isLive ? AnyShapeStyle(Color.accentColor.gradient) : AnyShapeStyle(.quaternary))
            )
    }
}

/// A tiny numbered badge marking a favorite slot (the Car Thing's buttons 1–4).
struct FavoriteBadge: View {
    let slot: Int

    var body: some View {
        Text("\(slot + 1)")
            .font(.system(size: 9, weight: .bold, design: .rounded))
            .foregroundStyle(.secondary)
            .frame(width: 15, height: 15)
            .background(Circle().strokeBorder(.secondary.opacity(0.6), lineWidth: 1))
            .help("Car Thing button \(slot + 1)")
    }
}

struct StatusDot: View {
    enum Tone { case good, pending, bad }
    let tone: Tone

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 7, height: 7)
    }

    private var color: Color {
        switch tone {
        case .good: .green
        case .pending: .orange
        case .bad: .red
        }
    }
}

extension SetupMonitor.Check {
    var tone: StatusDot.Tone {
        switch self {
        case .ok: .good
        case .pending: .pending
        case .problem: .bad
        }
    }

    var detail: String {
        switch self {
        case .ok(let text), .pending(let text), .problem(let text): text
        }
    }
}

extension Delivery {
    var label: String {
        switch self {
        case .direct: "Direct"
        case .converted: "Converting"
        case .unconverted: "Direct (FFmpeg missing)"
        }
    }

    var explanation: String? {
        switch self {
        case .direct: nil
        case .converted(let reason): "Converted with FFmpeg: \(reason.lowercased())."
        case .unconverted(let reason): "\(reason). Install FFmpeg for the best results."
        }
    }
}

extension CompanionAudio.Status {
    var label: String {
        switch self {
        case .off: "Mac audio off"
        case .waitingForDevice: "Waiting for the Car Thing"
        case .buffering: "Buffering audio…"
        case .playing: "In sync"
        case .unsynchronized: "Playing (this stream can't be synced)"
        }
    }
}

/// A hover-highlighted, full-width row button, matching native menu styling.
struct MenuRowButtonStyle: ButtonStyle {
    var isSelected = false
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(background(pressed: configuration.isPressed))
            )
            .onHover { isHovering = $0 }
    }

    private func background(pressed: Bool) -> Color {
        if isSelected { return Color.accentColor.opacity(0.18) }
        if pressed { return Color.primary.opacity(0.14) }
        return isHovering ? Color.primary.opacity(0.07) : .clear
    }
}
