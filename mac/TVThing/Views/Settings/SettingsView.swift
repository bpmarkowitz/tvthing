import SwiftUI

enum SettingsTab: String, Hashable {
    case channels, playback, carThing, diagnostics, about
}

/// The Settings window: a sidebar of sections, matching the layout of the Tabulate app.
struct SettingsView: View {
    @AppStorage("SelectedSettingsTab") private var selection: SettingsTab = .channels

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Label("Channels", systemImage: "list.number")
                    .tag(SettingsTab.channels)
                Label("Playback", systemImage: "speaker.wave.2.fill")
                    .tag(SettingsTab.playback)
                Label("Car Thing", systemImage: "cable.connector")
                    .tag(SettingsTab.carThing)
                Label("Diagnostics", systemImage: "stethoscope")
                    .tag(SettingsTab.diagnostics)
                Label("About", systemImage: "info.circle")
                    .tag(SettingsTab.about)
            }
            .toolbar(removing: .sidebarToggle)
            .navigationSplitViewColumnWidth(min: 160, ideal: 180)
        } detail: {
            switch selection {
            case .channels: ChannelsSettingsView()
            case .playback: PlaybackSettingsView()
            case .carThing: SetupSettingsView()
            case .diagnostics: DiagnosticsView()
            case .about: AboutView()
            }
        }
    }
}

struct AboutView: View {
    private static let repository = URL(string: "https://github.com/bpmarkowitz/tvthing")!
    private static let website = URL(string: "https://bpmarkowitz.com")!
    private let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–"

    var body: some View {
        Form {
            Section {
                VStack(spacing: 8) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 80, height: 80)
                    Text("TV Thing")
                        .font(.title2.weight(.semibold))
                    Text("A tiny TV for your Car Thing.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .listRowBackground(Color.clear)
            }

            Section {
                LabeledContent("Version") {
                    Text(version).foregroundStyle(.secondary)
                }
            }

            Section {
                LabeledContent("Developer") {
                    Text("Ben Markowitz").foregroundStyle(.secondary)
                }
                LabeledContent("Website") {
                    Link("bpmarkowitz.com", destination: Self.website)
                }
                LabeledContent("Source") {
                    Link("github.com/bpmarkowitz/tvthing", destination: Self.repository)
                }
            }
        }
        .formStyle(.grouped)
    }
}
