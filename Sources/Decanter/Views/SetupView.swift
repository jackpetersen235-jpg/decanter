import SwiftUI

/// Guides the user through the prerequisites: Rosetta 2 + a gaming-capable Wine build.
struct SetupView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                rosettaSection
                installationsSection
                helpSection
            }
            .padding(28)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Image(systemName: "wineglass.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)      // decorative
                Text("Welcome to Decanter").font(.largeTitle.bold())
            }
            Text("Create Windows “bottles” to run Steam and games on your Mac. "
                 + "Decanter drives a Wine translation layer; it needs Rosetta 2 and a "
                 + "gaming-capable Wine build to do the heavy lifting.")
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Rosetta

    private var rosettaSection: some View {
        GroupBox {
            HStack {
                statusDot(model.isRosettaInstalled)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Rosetta 2").font(.headline)
                    Text(model.isRosettaInstalled
                         ? "Installed — x86-64 Windows games can run."
                         : "Required to run the x86-64 Wine build and x86 games.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                if !model.isRosettaInstalled {
                    Button("Install Rosetta") { model.installRosetta() }
                        .buttonStyle(.borderedProminent)
                }
            }
            .padding(6)
        }
    }

    // MARK: Wine installations

    private var installationsSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Wine Builds").font(.headline)
                    Spacer()
                    Button("Rescan") { model.rescanInstallations() }
                    // Same action as Settings' button, so the same name (it was "Add Manually…").
                    Button("Add Wine Bin Folder…") { addManually() }
                }
                // Same reason Settings shows it: a button that does real work and says nothing is
                // one users conclude is broken. This one was silent while Settings' was not.
                if let msg = model.lastRescanMessage {
                    Text(msg).font(.caption).foregroundStyle(.secondary)
                }

                if model.installations.isEmpty {
                    HStack(spacing: 8) {
                        statusDot(false)
                        Text("No Wine build detected. Add one below, or install one (see options).")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    ForEach(model.installations) { installation in
                        installationRow(installation)
                    }
                }
            }
            .padding(6)
        }
    }

    private func installationRow(_ installation: WineInstallation) -> some View {
        HStack {
            // F9 (bug-sweep): `.onTapGesture` on a bare Image isn't exposed to VoiceOver as
            // interactive at all, regardless of any label — worse than the icon-only-button gap
            // elsewhere, since there was nothing here for a label to attach meaning to. F9 added
            // the label and a button TRAIT; it is now a real Button (2026-11-02), because a trait
            // only claims interactivity — a tap gesture still can't be reached from the keyboard.
            Button { model.defaultInstallationID = installation.id } label: {
                Image(systemName: model.defaultInstallationID == installation.id
                      ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(model.defaultInstallationID == installation.id
                                ? "Default Wine installation" : "Set as default Wine installation")
            VStack(alignment: .leading, spacing: 1) {
                Text(installation.name).font(.body.weight(.medium))
                Text(installation.version ?? installation.binDirectory.path)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if model.defaultInstallationID == installation.id {
                Text("Default").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: Help

    private var helpSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Text("Where to get a Wine build").font(.headline)
                bullet("Apple Game Porting Toolkit (GPTk) — best DirectX 12 → Metal performance. "
                       + "Install via Homebrew, then point Decanter at its bin folder.")
                bullet("CrossOver — commercial; Decanter detects it automatically at /Applications/CrossOver.app.")
                bullet("An existing Whisky install — its bundled Wine is detected automatically.")
                Text("Decanter installs its OWN Wine engine — use View ▸ Setup Assistant for that, and it is the recommended option. The builds above are alternatives you may already have; Decanter does not download those for you.")
                    .font(.caption).foregroundStyle(.secondary).padding(.top, 4)
            }
            .padding(6)
        }
    }

    // MARK: Helpers

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("•").foregroundStyle(.secondary)
            Text(text).foregroundStyle(.secondary)
        }
    }

    private func statusDot(_ ok: Bool) -> some View {
        Circle().fill(ok ? Color.green : Color.orange).frame(width: 10, height: 10)
    }

    private func addManually() {
        if let url = Panels.chooseDirectory(prompt: "Select Wine bin folder") {
            model.addWineDirectory(url)
        }
    }
}

/// Setup presented as a dismissable sheet from the main window toolbar.
struct SetupSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            SetupView()
            Divider()
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 720, height: 620)
        // Esc closes too: nothing here needs confirming — every change applies as it's made.
        .onExitCommand { dismiss() }
    }
}
