import SwiftUI

struct SetupSettingsView: View {
    var body: some View {
        Form {
            Section {
                SetupChecklist()
            } footer: {
                SetupInstructions()
            }
        }
        .formStyle(.grouped)
    }
}

/// Live status of everything TV Thing needs, with a fix-it action for each item.
struct SetupChecklist: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let setup = model.setup
        SetupRow(title: "Bridgething", check: setup.bridgething) {
            if !setup.bridgething.isOK {
                Button("Open Bridgething") { setup.openBridgething() }
            }
        }
        SetupRow(title: "TV Thing on the Car Thing", check: setup.carThing) {
            if setup.carThingBundle != nil {
                Button("Show Car Thing App") { setup.revealCarThingBundle() }
            }
        }
        SetupRow(title: "TV Thing service", check: setup.server) {
            EmptyView()
        }
        SetupRow(title: "FFmpeg (optional)", check: setup.ffmpeg) {
            if !setup.ffmpeg.isOK {
                Button("Copy Install Command") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(SetupMonitor.ffmpegInstallCommand, forType: .string)
                }
            }
        }
    }
}

private struct SetupRow<Action: View>: View {
    let title: String
    let check: SetupMonitor.Check
    @ViewBuilder let action: () -> Action

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(color)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(check.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            action()
        }
        .padding(.vertical, 2)
    }

    private var symbol: String {
        switch check {
        case .ok: "checkmark.circle.fill"
        case .pending: "clock.fill"
        case .problem: "exclamationmark.circle.fill"
        }
    }

    private var color: Color {
        switch check.tone {
        case .good: .green
        case .pending: .orange
        case .bad: .red
        }
    }
}

struct SetupInstructions: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Setting up the Car Thing")
                .font(.caption.weight(.semibold))
            Text("1. Install Bridgething on your Mac and the Car Thing, and connect the Car Thing by USB.")
            Text("2. Click **Show Car Thing App**, then install TVThing-CarThing.zip in Bridgething as a local app.")
            Text("3. Open TV Thing on the Car Thing. Buttons 1–4 play your favorites; the knob is volume. Press it to open the channel guide, turn to browse, and press again to watch.")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}
