import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var themeController: ThemeController

    /// What the last Rescan actually found.
    ///
    /// Rescan used to report NOTHING. When it found nothing new — the common case, since it only
    /// re-reads fixed locations — the button was indistinguishable from a broken one, which is
    /// exactly how it was reported. A control that does work silently is a control users conclude
    /// is dead.
    @State private var rescanResult: String?

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Theme", selection: $themeController.theme) {
                    ForEach(AppTheme.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.inline)
                Text(themeController.theme.detail)
                    .font(.caption).foregroundStyle(.secondary)

                Picker("Text colour", selection: $themeController.textTone) {
                    ForEach(TextTone.allCases) { Text($0.label).tag($0) }
                }
                Text("A clear window puts text over your wallpaper, and no one colour suits every "
                     + "desktop. Automatic keeps each theme's own choice.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Wine build for new bottles") {
                if model.installations.isEmpty {
                    Text("No Wine builds detected.").foregroundStyle(.secondary)
                } else {
                    Picker("Default", selection: Binding(
                        get: { model.defaultInstallationID ?? model.installations.first?.id ?? "" },
                        set: { model.defaultInstallationID = $0 }
                    )) {
                        ForEach(model.installations) { installation in
                            Text(installation.name).tag(installation.id)
                        }
                    }
                }
            }

            Section("Detected installations") {
                ForEach(model.installations) { installation in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(installation.name).font(.body.weight(.medium))
                        Text(installation.binDirectory.path)
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                HStack {
                    Button("Rescan") {
                        model.rescanInstallations()
                        rescanResult = model.rescanSummary()
                    }
                    Button("Add Wine bin folder…") {
                        if let url = Panels.chooseDirectory(prompt: "Select Wine bin folder") {
                            model.addWineDirectory(url)
                            rescanResult = "Added. Now \(model.installations.count) Wine build(s)."
                        }
                    }
                }
                if let rescanResult {
                    Text(rescanResult).font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("System") {
                LabeledContent("Rosetta 2") {
                    Label(model.isRosettaInstalled ? "Installed" : "Missing",
                          systemImage: model.isRosettaInstalled ? "checkmark.circle.fill" : "xmark.circle")
                        .foregroundStyle(model.isRosettaInstalled ? .green : .orange)
                }
                LabeledContent("Bottles folder") {
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.open(Paths.bottlesRoot)
                    }
                }
            }
        }
        .formStyle(.grouped)
        // Restrained: settings is well past eight rows, so it gets a solid fill — no atmosphere
        // behind the text and no gloss on rows.
        .themedBackground(restrained: true)
    }
}
