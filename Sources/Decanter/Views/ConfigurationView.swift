import SwiftUI

/// Editable configuration for one bottle. Edits persist immediately; the "Apply Settings to
/// Prefix" button pushes registry-backed settings (Windows version, retina, DPI) into Wine.
struct ConfigurationView: View {
    @EnvironmentObject private var model: AppModel
    @Binding var bottle: Bottle

    @State private var switchingEngine = false
    @State private var engineError: String?

    /// `borderlessFullscreen` and `nativeWindow` as the single choice they really are. They were
    /// two toggles that silently switched each other off, which reads as a bug — the HIG keeps
    /// toggles for independent on/off states and mutually exclusive options for a picker. Still
    /// stored as the same two settings, so `bottles.json` is unchanged.
    private enum WindowMode: String, CaseIterable, Identifiable {
        case gamesOwn = "Game's own setting"
        case borderless = "Borderless fullscreen"
        case nativeWindow = "Real game window"
        var id: String { rawValue }

        var detail: String {
            switch self {
            case .gamesOwn:
                return "The game uses whatever window or fullscreen mode it chooses itself."
            case .borderless:
                return "Runs the game in a real window sized to fill your screen, instead of "
                     + "whatever window mode it starts in — Cmd+Tab and the Dock still work. Use "
                     + "this for a game that doesn't fill the screen on its own or looks wrong in "
                     + "its normal fullscreen mode."
            case .nativeWindow:
                return "The game opens in an ordinary Mac window you can move, minimize, and take "
                     + "fullscreen with the green button — and macOS Game Mode turns on while it's "
                     + "fullscreen. Decanter starts the game itself instead of through Steam's Play "
                     + "button (Steam still runs alongside). Experimental: Borderless fullscreen is "
                     + "the mode frame pacing was tuned on."
            }
        }
    }

    private var windowMode: Binding<WindowMode> {
        Binding(
            get: {
                if bottle.settings.nativeWindow { return .nativeWindow }
                return bottle.settings.borderlessFullscreen ? .borderless : .gamesOwn
            },
            set: { mode in
                var settings = bottle.settings          // one write, not two
                settings.borderlessFullscreen = mode == .borderless
                settings.nativeWindow = mode == .nativeWindow
                bottle.settings = settings
            })
    }

    /// Bottles sharing `bottle`'s WINEPREFIX — Windows version, DPI and Retina all land in the
    /// registry ONCE PER PREFIX (HKLM, or HKCU keys the prefix itself owns), not once per bottle,
    /// so changing them here changes every bottle in this list too. Presented rather than hidden:
    /// F1 was exactly this shown as though each bottle were isolated.
    private var sharedWith: [Bottle] { model.otherBottlesSharingPrefix(with: bottle) }

    @ViewBuilder
    private func sharedCaption() -> some View {
        if !sharedWith.isEmpty {
            StatusNote("Also changes " + sharedWith.map(\.name).joined(separator: ", ")
                       + ", which share this bottle's prefix.")
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
            StatusNote("Set by whichever bottle starts Steam, for every game launched in that Steam "
                       + "session until it quits. Also affects "
                       + sharedWith.map(\.name).joined(separator: ", ") + ".")
        }
    }

    /// A setting's explanation, for the second line of its label.
    ///
    /// Styled by hand rather than left to the Form: the text-tone override (Settings ▸ Appearance)
    /// paints every `Text` in the detail column, and it turned the Form's own small grey subtitles
    /// into full-size primary text. Returns `Text`, not `some View`, so the Form still recognises
    /// it as the label's subtitle.
    private func subtitle(_ text: String) -> Text {
        Text(text).font(.caption).foregroundStyle(.secondary)
    }

    var body: some View {
        Form {
            // Explanations are SUBTITLES of the control they explain — a second `Text` in the
            // label, which a grouped Form draws under the title, the way System Settings does. They
            // used to be rows of their own, each with a separator above it, so a section read as a
            // stack of paragraphs with the controls lost between them. Notes about a whole section
            // go in its footer, outside the box. See `subtitle(_:)` for why they're styled by hand.
            Section {
                Picker(selection: Binding(
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
                } label: {
                    Text("Play mode")
                    subtitle((bottle.settings.engineProfile ?? .offline).detail)
                }
                .disabled(switchingEngine)

                if switchingEngine {
                    Text("Setting up…").font(.caption).foregroundStyle(.secondary)
                }
                if let engineError {
                    StatusNote(engineError)
                }

                if (bottle.settings.engineProfile ?? .offline) == .online {
                    // (No Divider above this: a grouped Form draws one as an empty row.)
                    LabeledContent {
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
                    } label: {
                        Text("Online engine")
                        subtitle("Restores a fresh copy from the offline engine if online play stops "
                             + "working. Takes about a second and never touches your offline setup.")
                    }
                }
            } header: {
                Text("Engine")
            } footer: {
                // Leading, explicitly: a macOS Form lays a multi-line footer out trailing-aligned,
                // which left its second line hanging off the right edge.
                Text("Both modes share this bottle — same games, same saves, same Steam login. "
                     + "Only the engine differs, so online changes can't affect your offline setup.")
                    .font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            // The shared-prefix note is the footer: it is about the whole section, and the header no
            // longer has to carry "— shared with this prefix" as well.
            Section {
                Picker("Windows version", selection: $bottle.settings.windowsVersion) {
                    ForEach(WindowsVersion.allCases) { Text($0.label).tag($0) }
                }
            } header: {
                Text("Windows")
            } footer: {
                sharedCaption()
            }

            Section("Graphics") {
                Picker(selection: $bottle.settings.graphics) {
                    ForEach(GraphicsBackend.allCases) { Text($0.label).tag($0) }
                } label: {
                    Text("Backend")
                    subtitle(bottle.settings.graphics.detail)
                }

                if bottle.settings.graphics == .dxmt || bottle.settings.graphics == .d3dmetal {
                    Toggle("MetalFX upscaling", isOn: $bottle.settings.metalFX)
                    if bottle.settings.metalFX {
                        Picker(selection: $bottle.settings.metalFXFactor) {
                            Text("1.3× (mild)").tag(1.3)
                            Text("1.5× (balanced)").tag(1.5)
                            Text("2.0× (max)").tag(2.0)
                        } label: {
                            Text("Upscale factor")
                            subtitle("MetalFX upscales from the game's own resolution — it doesn't lower "
                                 + "it. For more frames, also lower the game's resolution and let "
                                 + "MetalFX rebuild it to your display size.")
                        }
                    }
                    Toggle("Metal performance HUD", isOn: $bottle.settings.metalHUD)
                    envSharedCaption()
                }
                if bottle.settings.graphics == .dxvk {
                    Toggle("DXVK HUD (fps/frametimes)", isOn: $bottle.settings.dxvkHUD)
                }
                Toggle(isOn: $bottle.settings.software2D) {
                    Text("Old 2D game — software rendering")
                    subtitle("For pre-2010 2D games like Peggle, Bejeweled and Zuma, which draw "
                         + "thousands of sprites a frame — far slower through Wine on a Mac. "
                         + "Software rendering skips that (Peggle Deluxe: 18 → 90 fps). "
                         + "Leave off for 3D games.")
                }

                Picker(selection: windowMode) {
                    ForEach(WindowMode.allCases) { Text($0.rawValue).tag($0) }
                } label: {
                    Text("Window mode")
                    subtitle(windowMode.wrappedValue.detail)
                }
                if bottle.settings.nativeWindow,
                   let reason = model.nativeWindowUnavailableReason(for: bottle) {
                    StatusNote(reason)
                }

                Toggle("Retina / HiDPI mode", isOn: $bottle.settings.retinaMode)
                Stepper("Screen DPI: \(bottle.settings.dpi)",
                        value: $bottle.settings.dpi, in: 96...240, step: 24)
                sharedCaption()
            }

            Section("Performance") {
                // Fast sync is a property of the Wine BUILD, not a free choice. Builds without
                // it silently ignore WINEMSYNC/WINEESYNC — say so rather than imply otherwise.
                let install = model.installation(for: bottle)
                LabeledContent {
                    if let install {
                        // Tint on the icon only — green/orange text measures 2.2–2.3:1 on the light
                        // background (see StatusNote). Missed by the foundations pass: a ternary.
                        Label {
                            Text(install.supportsFastSync ? "Supported by this Wine build"
                                                          : "Not available in this Wine build")
                        } icon: {
                            Image(systemName: install.supportsFastSync ? "checkmark.circle.fill"
                                                                       : "exclamationmark.triangle.fill")
                                .foregroundStyle(install.supportsFastSync ? .green : .orange)
                        }
                    } else {
                        Text("No Wine build").foregroundStyle(.secondary)
                    }
                } label: {
                    Text("Fast sync (msync)")
                    // The old text here blamed wine 11 and pointed at CrossOver and a repo doc. The
                    // engine Decanter installs has msync (CLAUDE.md: "CrossOver is NOT needed"), so
                    // the useful thing to say is which engine to use.
                    if let install, !install.supportsFastSync {
                        subtitle("Without it, thread-heavy games get frame spikes. The Decanter "
                                 + "engine includes it.")
                    }
                }
                Picker("Thread sync", selection: $bottle.settings.syncMode) {
                    ForEach(SyncMode.allCases) { Text($0.label).tag($0) }
                }
                .disabled(!(install?.supportsFastSync ?? false))
                Toggle(isOn: $bottle.settings.advertiseAVX) {
                    Text("Advertise AVX to Rosetta")
                    subtitle("Several Game Porting Toolkit titles require AVX support to launch.")
                }
                envSharedCaption()
                Toggle("Verbose Wine logging", isOn: $bottle.settings.verboseLogging)
                // (No Divider here: a grouped Form draws one as an empty-looking row of its own.)
                Toggle(isOn: $bottle.settings.gpuKeepAlive) {
                    Text("GPU keep-alive")
                    subtitle("Works around a GPU firmware fault on some Apple Silicon Macs that causes "
                         + "occasional multi-second whole-system freezes during play. Only turn it "
                         + "on if you've seen those freezes — it runs a small background GPU load "
                         + "for as long as the game does.")
                }
            }

            Section("Steam launch arguments") {
                // The example shows the one argument that matters: `-applaunch <app id>` is what
                // makes this a game bottle that Play launches (Sekiro's id here).
                // Label hidden: the section header already names it, and the monospaced font set on
                // the field was also setting the label in code type. VoiceOver still reads it.
                TextField("Steam launch arguments", text: $bottle.settings.steamArguments,
                          prompt: Text("e.g. -applaunch 814380"))
                    .labelsHidden()
                    .font(.system(.body, design: .monospaced))
            }

            Section {
                LabeledContent {
                    Button("Apply Settings to Prefix") { model.applySettings(bottle) }
                        .disabled(!bottle.isInitialized)
                } label: {
                    Text("Registry settings")
                    subtitle("Windows version, Retina and DPI are written to Wine when you press Apply.")
                }
            }
        }
        .formStyle(.grouped)
        // On the Form itself. The glass pane's own setting stops at the detail ScrollView.
        .glassFormBackground()
        .padding(.horizontal, 4)
        // Dense screen: engine, window, graphics and sync sections run well past eight rows, so
        // this takes the restrained variant — solid fill, no atmosphere behind the text.
        .themedBackground(restrained: true)
    }
}
