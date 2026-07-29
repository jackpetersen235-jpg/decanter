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
    @State private var installingGFX = false
    @State private var gfxResult: String?

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
                    // An engine older than wine 8 will start Steam and then kill it with
                    // "Failed to load steamui.dll" — a fatal error that names a DLL instead of the
                    // real cause. Say so BEFORE the user clicks Launch.
                    if let inst = model.installation(for: bottle), !inst.isSteamCapable {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("This bottle's engine is too old for Steam")
                                    .font(.callout.weight(.semibold))
                                Text("\(inst.name) \(inst.version ?? "") cannot load modern Steam "
                                     + "(it fails with \"Failed to load steamui.dll\"). "
                                     + "Run View ▸ Setup Assistant to install the Decanter engine, "
                                     + "then make a new bottle.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        }
                        .padding(.bottom, 4)
                    }

                    if bottle.isSteamInstalled {
                        let launching = model.launchingBottleIDs.contains(bottle.id)
                        Text("Steam is installed in this bottle.").foregroundStyle(.secondary)
                        HStack {
                            Button {
                                model.launchSteam(in: bottle)
                            } label: {
                                if launching {
                                    Label("Opening…", systemImage: "hourglass")
                                } else {
                                    Label("Launch Steam", systemImage: "play.fill")
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(launching)

                            Button("Reinstall") { model.installSteam(in: bottle) }

                            // Re-runnable on purpose: the wizard installs this after Steam, but a
                            // fresh library has no games yet, so it must be reachable afterwards.
                            Button(installingGFX ? "Installing…" : "Install Graphics Driver") {
                                installingGFX = true
                                Task {
                                    let n = await model.installGraphicsDriver(in: bottle)
                                    gfxResult = n == 0
                                        ? "No games found in this bottle yet — install one in Steam, then run this again."
                                        : "Patched graphics driver installed for \(n) game\(n == 1 ? "" : "s")."
                                    installingGFX = false
                                }
                            }
                            .disabled(installingGFX)
                        }
                        if let gfxResult {
                            Text(gfxResult).font(.caption).foregroundStyle(.secondary)
                        }
                        if launching {
                            Text("Steam is opening — this can take a few seconds the first time.")
                                .font(.caption).foregroundStyle(.secondary)
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
