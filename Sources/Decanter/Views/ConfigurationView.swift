import SwiftUI

/// Editable configuration for one bottle. Edits persist immediately; the "Apply to
/// Prefix" button pushes registry-backed settings (Windows version, retina, DPI) into Wine.
struct ConfigurationView: View {
    @EnvironmentObject private var model: AppModel
    @Binding var bottle: Bottle

    @State private var switchingEngine = false
    @State private var engineError: String?

    /// Bottles sharing `bottle`'s WINEPREFIX — Windows version, DPI and Retina all land in the
    /// registry ONCE PER PREFIX (HKLM, or HKCU keys the prefix itself owns), not once per bottle,
    /// so changing them here changes every bottle in this list too. Presented rather than hidden:
    /// F1 was exactly this shown as though each bottle were isolated.
    private var sharedWith: [Bottle] { model.otherBottlesSharingPrefix(with: bottle) }

    @ViewBuilder
    private func sharedCaption() -> some View {
        if !sharedWith.isEmpty {
            Text("This is a property of the PREFIX, not this bottle. Changing it also changes: "
                 + sharedWith.map(\.name).joined(separator: ", "))
                .font(.caption).foregroundStyle(.orange)
        }
    }

    /// F14 (bug-sweep): `sharedCaption()` above covers settings that land in the registry — always
    /// and permanently shared across every bottle on this prefix. MetalFX, its upscale factor, the
    /// Metal HUD, thread sync, and "advertise AVX" are a DIFFERENT kind of shared: they're baked
    /// into whichever bottle's `Play` starts Steam, then inherited by every `-applaunch` game
    /// through that same Steam session until it quits — not a permanent prefix property, but not
    /// safely "this bottle's own setting" either. Before this fix, `sharedCaption()` sat at the
    /// bottom of a section covering both kinds of setting, which read as though it covered
    /// everything above it — accidentally right for some rows, silently wrong for others. This
    /// caption is worded for the session-scoped mechanism specifically, and sits immediately after
    /// the controls it actually describes, not shared with the registry caption's placement.
    @ViewBuilder
    private func envSharedCaption() -> some View {
        if !sharedWith.isEmpty {
            Text("This takes effect through Steam's own launch environment, not the registry — "
                 + "whichever bottle starts Steam decides it for every game launched through that "
                 + "same Steam session, until Steam quits. Also affects: "
                 + sharedWith.map(\.name).joined(separator: ", "))
                .font(.caption).foregroundStyle(.orange)
        }
    }

    var body: some View {
        Form {
            Section("Engine") {
                Picker("Play mode", selection: Binding(
                    get: { bottle.settings.engineProfile ?? .offline },
                    set: { profile in
                        // Routed through the model rather than written straight to the binding:
                        // choosing Online may need to create that engine first, and the switch has
                        // to be refused while the game is running.
                        switchingEngine = true
                        engineError = nil
                        Task {
                            engineError = await model.setEngineProfile(profile, for: bottle)
                            switchingEngine = false
                        }
                    })) {
                    ForEach(EngineProfile.allCases) { Text($0.label).tag($0) }
                }
                .disabled(switchingEngine)

                Text((bottle.settings.engineProfile ?? .offline).detail)
                    .font(.caption).foregroundStyle(.secondary)

                if switchingEngine {
                    Text("Setting up…").font(.caption).foregroundStyle(.secondary)
                }
                if let engineError {
                    Label(engineError, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                }
                Text("Both modes share this bottle — same games, same saves, same Steam login. "
                     + "Only the engine differs, so online changes can't affect your offline setup.")
                    .font(.caption).foregroundStyle(.secondary)

                if (bottle.settings.engineProfile ?? .offline) == .online {
                    Divider()
                    Button(switchingEngine ? "Working…" : "Reset Online Engine") {
                        switchingEngine = true
                        engineError = nil
                        Task {
                            let ok = await model.resetOnlineEngine()
                            engineError = ok ? nil : "Quit Steam and any running game first."
                            switchingEngine = false
                        }
                    }
                    .disabled(switchingEngine)
                    Text("Restores a fresh copy from the offline engine. Use this if online play "
                         + "stops working after changing something — it takes about a second and "
                         + "never touches your offline setup.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section(sharedWith.isEmpty ? "Windows" : "Windows — shared with this prefix") {
                Picker("Windows version", selection: $bottle.settings.windowsVersion) {
                    ForEach(WindowsVersion.allCases) { Text($0.label).tag($0) }
                }
                sharedCaption()
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
                    envSharedCaption()
                }
                if bottle.settings.graphics == .dxvk {
                    Toggle("DXVK HUD (fps/frametimes)", isOn: $bottle.settings.dxvkHUD)
                }
                Toggle("Old 2D game — software rendering", isOn: $bottle.settings.software2D)
                Text("For pre-2010 2D games (Peggle, Bejeweled, Zuma…). They draw every sprite as a "
                     + "separate call — thousands per frame — and each one is far more expensive "
                     + "through Wine on a Mac than on Windows. Rendering in software skips that "
                     + "entirely. Measured on Peggle Deluxe: 18 fps → 90 fps. Leave OFF for 3D games.")
                    .font(.caption).foregroundStyle(.secondary)

                Toggle("Retina / HiDPI mode", isOn: $bottle.settings.retinaMode)
                Stepper("Screen DPI: \(bottle.settings.dpi)",
                        value: $bottle.settings.dpi, in: 96...240, step: 24)
                sharedCaption()
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
                envSharedCaption()
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
        // Dense screen: engine, window, graphics and sync sections run well past eight rows, so
        // this takes the restrained variant — solid fill, no atmosphere behind the text.
        .themedBackground(restrained: true)
    }
}
