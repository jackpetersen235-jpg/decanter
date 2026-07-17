import SwiftUI

/// Editable configuration for one bottle. Edits persist immediately; the "Apply to
/// Prefix" button pushes registry-backed settings (Windows version, retina, DPI) into Wine.
struct ConfigurationView: View {
    @EnvironmentObject private var model: AppModel
    @Binding var bottle: Bottle

    var body: some View {
        Form {
            Section("Windows") {
                Picker("Windows version", selection: $bottle.settings.windowsVersion) {
                    ForEach(WindowsVersion.allCases) { Text($0.label).tag($0) }
                }
            }

            Section("Graphics") {
                Picker("Backend", selection: $bottle.settings.graphics) {
                    ForEach(GraphicsBackend.allCases) { Text($0.label).tag($0) }
                }
                Text(bottle.settings.graphics.detail)
                    .font(.caption).foregroundStyle(.secondary)

                if bottle.settings.graphics == .d3dmetal {
                    Toggle("MetalFX upscaling", isOn: $bottle.settings.metalFX)
                    Toggle("Metal performance HUD", isOn: $bottle.settings.metalHUD)
                }
                if bottle.settings.graphics == .dxvk {
                    Toggle("DXVK HUD (fps/frametimes)", isOn: $bottle.settings.dxvkHUD)
                }
                Toggle("Retina / HiDPI mode", isOn: $bottle.settings.retinaMode)
                Stepper("Screen DPI: \(bottle.settings.dpi)",
                        value: $bottle.settings.dpi, in: 96...240, step: 24)
            }

            Section("Performance") {
                Picker("Thread sync", selection: $bottle.settings.syncMode) {
                    ForEach(SyncMode.allCases) { Text($0.label).tag($0) }
                }
                Toggle("Advertise AVX to Rosetta", isOn: $bottle.settings.advertiseAVX)
                Text("Several Game Porting Toolkit titles require AVX support to launch.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Verbose Wine logging", isOn: $bottle.settings.verboseLogging)
            }

            Section("Steam launch arguments") {
                TextField("Arguments", text: $bottle.settings.steamArguments)
                    .font(.system(.body, design: .monospaced))
            }

            Section {
                HStack {
                    Text("Registry-backed settings (Windows version, retina, DPI) apply when you press this.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Apply to Prefix") { model.applySettings(bottle) }
                        .disabled(!bottle.isInitialized)
                }
            }
        }
        .formStyle(.grouped)
        .padding(.horizontal, 4)
    }
}
