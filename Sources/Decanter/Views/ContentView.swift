import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showingCreate = false
    @State private var showingSetup = false

    var body: some View {
        Group {
            if model.installations.isEmpty && model.bottles.isEmpty {
                // Nothing to work with yet — walk the user through Wine setup first.
                SetupView()
            } else {
                splitView
            }
        }
        .sheet(isPresented: $showingCreate) { CreateBottleSheet() }
        .sheet(isPresented: $showingSetup) { SetupSheet() }
        .sheet(item: $model.activeConsole) { console in
            ConsoleView(console: console)
        }
        .onReceive(NotificationCenter.default.publisher(for: .newBottleRequested)) { _ in
            showingCreate = true
        }
    }

    private var splitView: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail.wallpaper()
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            List(selection: $model.selectedBottleID) {
                Section("Bottles") {
                    ForEach(model.bottles) { bottle in
                        BottleRow(bottle: bottle)
                            .tag(bottle.id)
                            .contextMenu { bottleContextMenu(bottle) }
                    }
                }
            }
            Divider()
            wineStatusFooter
        }
        .frame(minWidth: 240)
        .toolbar {
            ToolbarItem {
                Button { showingCreate = true } label: {
                    Label("New Bottle", systemImage: "plus")
                }
                .help("Create a new bottle")
                .disabled(model.defaultInstallation == nil)
            }
            ToolbarItem {
                Button { showingSetup = true } label: {
                    Label("Setup", systemImage: "gearshape")
                }
                .help("Wine installations & system checks")
            }
        }
    }

    @ViewBuilder
    private func bottleContextMenu(_ bottle: Bottle) -> some View {
        Button("Open C: Drive") { model.openCDrive(bottle) }
        Button("Apply Settings to Prefix") { model.applySettings(bottle) }
        Divider()
        Button("Delete Bottle (keep files)") { model.deleteBottle(bottle, removeFiles: false) }
        Button("Delete Bottle & Files", role: .destructive) {
            model.deleteBottle(bottle, removeFiles: true)
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let id = model.selectedBottleID,
           let bottle = model.bottles.first(where: { $0.id == id }) {
            BottleDetailView(bottle: bottle)
        } else {
            VStack(spacing: 12) {
                Image(systemName: "wineglass")
                    .font(.system(size: 48))
                    .foregroundStyle(.secondary)
                Text("Select a bottle")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                if model.defaultInstallation != nil {
                    Button("Create a Bottle") { showingCreate = true }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var wineStatusFooter: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(model.defaultInstallation != nil ? Color.green : Color.orange)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                if let installation = model.defaultInstallation {
                    Text(installation.name).font(.caption).lineLimit(1)
                    Text(installation.version ?? "Wine build detected")
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                } else {
                    Text("No Wine build found").font(.caption)
                    Text("Open Setup to add one").font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

/// One row in the bottle sidebar.
private struct BottleRow: View {
    let bottle: Bottle

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: bottle.isSteamInstalled ? "gamecontroller.fill" : "cube.box")
                .foregroundStyle(bottle.isSteamInstalled ? Color.accentColor : .secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(bottle.name).lineLimit(1)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }

    private var subtitle: String {
        if !bottle.isInitialized { return "Initializing…" }
        if bottle.isSteamInstalled { return "Steam ready" }
        return bottle.settings.windowsVersion.label
    }
}
