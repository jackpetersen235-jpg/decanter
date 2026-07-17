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

                if bottle.settings.graphics == .dxmt || bottle.settings.graphics == .d3dmetal {
                    Toggle("MetalFX upscaling", isOn: $bottle.settings.metalFX)
                    if bottle.settings.metalFX {
                        Picker("Upscale factor", selection: $bottle.settings.metalFXFactor) {
                            Text("1.3× (mild)").tag(1.3)
                            Text("1.5× (balanced)").tag(1.5)
                            Text("2.0× (max)").tag(2.0)
                        }
                        Text("MetalFX upscales *from* the game's own resolution — it doesn't lower it. "
                             + "For actual frames, also reduce the game's internal resolution and let "
                             + "MetalFX rebuild it to your display size.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
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
                // Fast sync is a property of the Wine BUILD, not a free choice. Builds without
                // it silently ignore WINEMSYNC/WINEESYNC — say so rather than imply otherwise.
                let install = model.installation(for: bottle)
                LabeledContent("Fast sync (msync)") {
                    if let install {
                        Label(install.supportsFastSync ? "Supported by this Wine build"
                                                       : "Not available in this Wine build",
                              systemImage: install.supportsFastSync ? "checkmark.circle.fill"
                                                                    : "exclamationmark.triangle.fill")
                            .foregroundStyle(install.supportsFastSync ? .green : .orange)
                    } else {
                        Text("No Wine build").foregroundStyle(.secondary)
                    }
                }
                if let install, !install.supportsFastSync {
                    Text("Without msync/esync every Windows mutex round-trips through wineserver, "
                         + "which causes frame spikes in thread-heavy games. wine 11 has no fast sync "
                         + "on macOS; only CrossOver-derived builds do. See docs/GAMING-STACK.md.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Picker("Thread sync", selection: $bottle.settings.syncMode) {
                    ForEach(SyncMode.allCases) { Text($0.label).tag($0) }
                }
                .disabled(!(install?.supportsFastSync ?? false))
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
