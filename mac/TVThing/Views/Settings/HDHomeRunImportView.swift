import SwiftUI
import TVThingKit

/// Finds HDHomeRun tuners on the network and imports a tuner's whole channel lineup.
struct HDHomeRunImportView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var devices: [HDHomeRun.Device] = []
    @State private var searching = true
    @State private var manualHost = ""
    @State private var importing = false
    @State private var message: String?
    @State private var failed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Import from HDHomeRun")
                .font(.title3.weight(.semibold))
            Text("Adds every channel your tuner receives. Each channel you watch uses one of its tuners, and needs FFmpeg to convert it for the Car Thing.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    if searching {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Looking for tuners on your network…").foregroundStyle(.secondary)
                        }
                    } else if devices.isEmpty {
                        Text("No tuners found. Enter your HDHomeRun's IP address below.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(devices) { device in
                        HStack {
                            Image(systemName: "antenna.radiowaves.left.and.right")
                            VStack(alignment: .leading) {
                                Text(device.name)
                                Text("\(device.host) · \(device.tunerCount) tuners")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Import Channels") { importLineup(from: device.host) }
                                .disabled(importing)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            }

            HStack {
                TextField("IP address", text: $manualHost, prompt: Text("e.g. 192.168.1.50"))
                    .onSubmit { importLineup(from: manualHost) }
                Button("Import") { importLineup(from: manualHost) }
                    .disabled(manualHost.trimmingCharacters(in: .whitespaces).isEmpty || importing)
            }

            if let message {
                Label(message, systemImage: failed ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(failed ? .red : .green)
                    .font(.callout)
            }

            HStack {
                if importing { ProgressView().controlSize(.small) }
                Spacer()
                Button(message != nil && !failed ? "Done" : "Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 480)
        .task {
            devices = await HDHomeRun.discover()
            searching = false
        }
    }

    private func importLineup(from host: String) {
        let host = host.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty else { return }
        importing = true
        message = nil
        Task {
            defer { importing = false }
            do {
                message = try await model.importHDHomeRun(at: host)
                failed = false
            } catch {
                message = "Couldn't read channels from \(host): \(error.localizedDescription)"
                failed = true
            }
        }
    }
}
