import SwiftUI

struct BottleDetailView: View {
    @EnvironmentObject private var model: AppModel
    let bottle: Bottle

    private enum Tab: String, CaseIterable, Identifiable {
        case overview = "Overview"
        case configuration = "Configuration"
        case programs = "Programs"
        var id: String { rawValue }
    }
    @State private var tab: Tab = .overview

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerBar
            Divider()
            Picker("", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(12)

            ScrollView {
                switch tab {
                case .overview:      overview
                case .configuration: ConfigurationView(bottle: model.binding(for: bottle))
                case .programs:      ProgramsView(bottle: bottle)
                }
            }
        }
        .navigationTitle(bottle.name)
    }

    // MARK: Header

    private var headerBar: some View {
        HStack(spacing: 14) {
            Image(systemName: "cube.box.fill")
                .font(.system(size: 30))
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(bottle.name).font(.title2.bold())
                Text(model.installation(for: bottle)?.name ?? "No Wine build")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !bottle.isInitialized {
                ProgressView().controlSize(.small)
                Text("Setting up…").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(16)
    }

    // MARK: Overview

    private var overview: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Primary gaming actions.
            GroupBox("Steam") {
                VStack(alignment: .leading, spacing: 12) {
                    if bottle.isSteamInstalled {
                        Text("Steam is installed in this bottle.").foregroundStyle(.secondary)
                        HStack {
                            Button {
                                model.launchSteam(in: bottle)
                            } label: {
                                Label("Launch Steam", systemImage: "play.fill")
                            }
                            .buttonStyle(.borderedProminent)

                            Button("Reinstall") { model.installSteam(in: bottle) }
                        }
                    } else {
                        Text("Install the Steam client to start downloading and playing games.")
                            .foregroundStyle(.secondary)
                        Button {
                            model.installSteam(in: bottle)
                        } label: {
                            Label("Install Steam", systemImage: "arrow.down.circle.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!bottle.isInitialized)
                    }
                }
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            GroupBox("Bottle") {
                VStack(alignment: .leading, spacing: 10) {
                    infoRow("Windows version", bottle.settings.windowsVersion.label)
                    infoRow("Graphics", bottle.settings.graphics.label)
                    infoRow("Sync", bottle.settings.syncMode.label)
                    infoRow("Prefix", bottle.url.path, mono: true)
                    HStack {
                        Button("Open C: Drive") { model.openCDrive(bottle) }
                        Button("Apply Settings") { model.applySettings(bottle) }
                        Button("Wine Config") { model.runTool(.winecfg, in: bottle) }
                    }
                    .padding(.top, 4)
                }
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(16)
    }

    private func infoRow(_ label: String, _ value: String, mono: Bool = false) -> some View {
        HStack(alignment: .top) {
            Text(label).foregroundStyle(.secondary).frame(width: 130, alignment: .leading)
            Text(value)
                .font(mono ? .system(.caption, design: .monospaced) : .body)
                .textSelection(.enabled)
            Spacer()
        }
    }
}
