import SwiftUI
import TVThingKit

/// Recent events from the Mac and the Car Thing, for troubleshooting and bug reports.
struct DiagnosticsView: View {
    @Environment(AppModel.self) private var model
    @State private var entries: [DiagnosticsLog.Entry] = []

    var body: some View {
        VStack(spacing: 0) {
            if entries.isEmpty {
                ContentUnavailableView("No Events Yet", systemImage: "text.alignleft", description: Text("Tuning, conversion, and Car Thing messages appear here."))
            } else {
                ScrollViewReader { proxy in
                    List(entries) { entry in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(entry.date, format: .dateTime.hour().minute().second())
                                .foregroundStyle(.secondary)
                            Text(entry.source == .device ? "CAR" : "MAC")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(entry.source == .device ? Color.accentColor : .secondary)
                                .frame(width: 30, alignment: .leading)
                            Text(entry.message)
                                .textSelection(.enabled)
                        }
                        .font(.system(.caption, design: .monospaced))
                        .id(entry.id)
                    }
                    .onChange(of: entries.last?.id) { _, id in
                        if let id { proxy.scrollTo(id, anchor: .bottom) }
                    }
                }
            }
            Divider()
            HStack {
                Text("TV Thing \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Restart Stream") { model.restartStream() }
                Button("Copy Log") { copyLog() }
                    .disabled(entries.isEmpty)
                Button("Clear") {
                    Task {
                        await model.engine.log.clear()
                        entries = []
                    }
                }
            }
            .padding(10)
        }
        .task {
            while !Task.isCancelled {
                entries = await model.engine.log.recent()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func copyLog() {
        let formatter = ISO8601DateFormatter()
        let text = entries
            .map { "\(formatter.string(from: $0.date)) [\($0.source.rawValue)] \($0.message)" }
            .joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
