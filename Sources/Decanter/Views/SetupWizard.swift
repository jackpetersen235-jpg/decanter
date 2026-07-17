import SwiftUI

/// First-run experience. Goal: a person who has never heard of Wine can press one button
/// and end up with Steam running. Every step self-checks, self-installs, and explains itself
/// in plain language — no jargon, no file paths, no terminal.
struct SetupWizard: View {
    /// Non-nil when shown on demand (menu) rather than as the first-run screen.
    var dismiss: (() -> Void)? = nil
    @EnvironmentObject private var model: AppModel
    @StateObject private var installer = WineInstaller()
    @State private var running = false
    @State private var bottleName = "Games"

    private enum Step: Int, CaseIterable {
        case rosetta, engine, bottle, steam

        var title: String {
            switch self {
            case .rosetta: return "Apple's translation layer"
            case .engine:  return "The Windows engine"
            case .bottle:  return "A place for your games"
            case .steam:   return "Steam"
            }
        }
        var blurb: String {
            switch self {
            case .rosetta: return "Lets your Mac understand software written for Intel chips. Made by Apple, already on most Macs."
            case .engine:  return "Translates Windows games so they run on macOS. About 317 MB — Decanter downloads and sets it up for you."
            case .bottle:  return "A private Windows environment for your games. Nothing leaks into the rest of your Mac."
            case .steam:   return "The Steam app itself, installed inside that environment."
            }
        }
        var icon: String {
            switch self {
            case .rosetta: return "cpu"
            case .engine:  return "gearshape.2"
            case .bottle:  return "cube.box"
            case .steam:   return "gamecontroller"
            }
        }
    }

    // MARK: State of each step

    private func isDone(_ step: Step) -> Bool {
        switch step {
        case .rosetta: return model.isRosettaInstalled
        case .engine:  return model.defaultInstallation != nil
        case .bottle:  return !model.bottles.isEmpty
        case .steam:   return model.bottles.contains { $0.isSteamInstalled }
        }
    }

    private var firstUnfinished: Step? { Step.allCases.first { !isDone($0) } }
    private var allDone: Bool { firstUnfinished == nil }

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                header
                VStack(spacing: 10) {
                    ForEach(Step.allCases, id: \.rawValue) { row($0) }
                }
                .frame(maxWidth: 620)
                actionArea
                    .frame(maxWidth: 620)
            }
            .padding(30)
            .frame(maxWidth: .infinity)
        }
    }

    private var header: some View {
        VStack(spacing: 8) {
            Image(systemName: "wineglass.fill")
                .font(.system(size: 40))
                .foregroundStyle(Color.accentColor)
            Text("Let's get you playing").font(.largeTitle.bold())
            Text(allDone
                 ? "Everything's ready."
                 : "Decanter needs four things. It can set up all of them for you — just press the button.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private func row(_ step: Step) -> some View {
        let done = isDone(step)
        let active = running && firstUnfinished == step
        return HStack(alignment: .top, spacing: 14) {
            ZStack {
                Circle()
                    .fill(done ? Color.green.opacity(0.15)
                               : (active ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.1)))
                    .frame(width: 34, height: 34)
                if done {
                    Image(systemName: "checkmark").foregroundStyle(.green).font(.system(size: 15, weight: .bold))
                } else if active {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: step.icon).foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(step.title).font(.body.weight(.semibold))
                Text(step.blurb).font(.caption).foregroundStyle(.secondary)
                if step == .engine, case .downloading(let p) = installer.phase, active {
                    ProgressView(value: p) {
                        Text("Downloading… \(Int(p * 100))%").font(.caption2)
                    }
                    .padding(.top, 2)
                }
                if step == .engine, active, installer.phase == .extracting {
                    Text("Unpacking…").font(.caption2).foregroundStyle(.secondary)
                }
                if case .failed(let message) = installer.phase, step == .engine {
                    Text(message).font(.caption2).foregroundStyle(.red)
                }
            }
            Spacer()
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.06)))
    }

    @ViewBuilder
    private var actionArea: some View {
        if allDone {
            VStack(spacing: 10) {
                Button {
                    if let b = model.bottles.first(where: { $0.isSteamInstalled }) {
                        model.selectedBottleID = b.id
                    }
                    dismiss?()
                } label: {
                    Label("Start using Decanter", systemImage: "arrow.right.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        } else {
            VStack(spacing: 10) {
                Button {
                    Task { await runAll() }
                } label: {
                    Label(running ? "Setting things up…" : "Set everything up for me",
                          systemImage: running ? "hourglass" : "wand.and.stars")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(running)

                Text(running
                     ? "This can take several minutes. You can leave it running."
                     : "Downloads about 317 MB. Nothing else on your Mac is touched.")
                    .font(.caption).foregroundStyle(.secondary)

                if !model.isRosettaInstalled {
                    Text("macOS may ask for your password to install Apple's translation layer.")
                        .font(.caption2).foregroundStyle(.orange)
                }
            }
        }
    }

    // MARK: The automation

    private func runAll() async {
        running = true
        defer { running = false }

        // 1. Rosetta — Apple's installer prompts for admin itself.
        if !model.isRosettaInstalled {
            model.installRosetta()
            // Give the installer a chance; it's user-driven so we don't block forever.
            for _ in 0..<60 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                model.isRosettaInstalled = SystemChecks.isRosettaInstalled
                if model.isRosettaInstalled { break }
            }
        }

        // 2. Engine — download + unpack + verify.
        if model.defaultInstallation == nil {
            await installer.install()
            model.rescanInstallations()
            if case .failed = installer.phase { return }
        }

        // 3. Bottle.
        if model.bottles.isEmpty, model.defaultInstallation != nil {
            model.createBottle(name: bottleName)
            for _ in 0..<120 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if model.bottles.first?.isInitialized == true { break }
            }
        }

        // 4. Steam.
        if let bottle = model.bottles.first, !bottle.isSteamInstalled {
            model.installSteam(in: bottle)
            for _ in 0..<300 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if model.bottles.first?.isSteamInstalled == true { break }
            }
        }
    }
}
