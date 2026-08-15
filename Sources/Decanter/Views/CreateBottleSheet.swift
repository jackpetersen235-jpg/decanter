import SwiftUI
import UniformTypeIdentifiers

struct CreateBottleSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var name: String = ""

    /// nil while the first scan is running, so the list can say "Scanning…" rather than
    /// "No games found" — which would be a lie for the second or two the walk takes.
    @State private var found: [GameScanner.FoundGame]?
    @State private var selected: GameScanner.FoundGame?
    /// Set by "Choose a Program…", the bypass for anything the scan misses.
    @State private var manualExecutable: URL?
    /// Why the sheet could not do what was asked. Previously it just dismissed.
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New Bottle").font(.title2.bold())
            Text("Pick a game Decanter found, or make an empty bottle to install something new.")
                .font(.callout).foregroundStyle(.secondary)

            gameList

            Divider()

            Form {
                TextField("Name", text: $name, prompt: Text(namePrompt))
                LabeledContent("Wine build") {
                    Text(model.defaultInstallation?.name ?? "None")
                        .foregroundStyle(model.defaultInstallation == nil ? .red : .primary)
                }
                if let manualExecutable {
                    LabeledContent("Program") {
                        Text(manualExecutable.lastPathComponent)
                            .font(.system(.caption, design: .monospaced))
                    }
                }
            }
            .formStyle(.grouped)

            if model.defaultInstallation == nil {
                Label("No Wine build selected. Add one in Setup first.",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
            if let failure {
                Label(failure, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }

            HStack {
                // THE BYPASS. The scan only looks in the places installers normally use, so
                // anything unpacked by hand — or any prefix Decanter has never seen — needs a way
                // in that does not depend on the scan being right.
                Button("Choose a Program…") { chooseManually() }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(createTitle) { create() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.defaultInstallation == nil)
            }
        }
        .padding(20)
        .frame(width: 540)
        // The scan list plus the form is a dense screen, and a sheet has no room for atmosphere.
        .themedBackground(restrained: true)
        .task {
            // Read the prefixes on the main actor, then walk the filesystem OFF it. Passing the
            // model into a detached task would not help: AppModel is @MainActor, so calling one of
            // its methods there hops straight back and the sheet freezes anyway.
            let prefixes = model.scannablePrefixes
            found = await Task.detached(priority: .userInitiated) {
                AppModel.scanForGames(in: prefixes)
            }.value
        }
    }

    // MARK: Game list

    @ViewBuilder
    private var gameList: some View {
        GroupBox("Games found on your C: drive") {
            Group {
                if found == nil {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Scanning…").foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 6)
                } else if found?.isEmpty == true {
                    Text("No games found. Use “Choose a Program…” to point at one directly, "
                         + "or make an empty bottle and install a game into it.")
                        .font(.callout).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 6)
                } else {
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(found ?? []) { game in
                                row(game)
                                Divider()
                            }
                        }
                    }
                    .frame(height: 150)
                }
            }
            .padding(4)
        }
    }

    private func row(_ game: GameScanner.FoundGame) -> some View {
        let isSelected = selected?.id == game.id
        return HStack(spacing: 10) {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "gamecontroller")
                .foregroundStyle(isSelected ? Color.accentColor : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(game.name).lineLimit(1)
                // Name the executable AND the prefix. The executable because the scan picks the
                // biggest one and on Unreal titles that is a deep Shipping.exe — a wrong pick
                // should be visible before the bottle is created, not after it fails to launch.
                // The prefix because the same game can legitimately exist in two of them (Half
                // Sword is in both here), and without it the list shows two identical rows.
                Text("\(game.executable.lastPathComponent) · \(game.displaySize) · in \(game.prefix.lastPathComponent)")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            // Flag games that already have a bottle. Picking one is still allowed — a second
            // bottle with different settings is legitimate — but it should be a decision, not a
            // surprise, and the new bottle's name gets numbered rather than colliding.
            if model.existingBottle(for: game) != nil {
                Text("Added").font(.caption2)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Color.accentColor.opacity(0.22), in: Capsule())
            }
            if game.appID != nil {
                Text("Steam").font(.caption2)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Color.secondary.opacity(0.18), in: Capsule())
            }
        }
        .padding(.vertical, 5).padding(.horizontal, 4)
        .contentShape(Rectangle())
        .background(isSelected ? Color.accentColor.opacity(0.12) : .clear)
        .onTapGesture {
            if isSelected { selected = nil } else {
                selected = game
                manualExecutable = nil          // the two choices are exclusive
                if name.isEmpty { name = game.name }
            }
        }
    }

    // MARK: Actions

    private var namePrompt: String {
        selected?.name ?? manualExecutable?.deletingPathExtension().lastPathComponent
            ?? "e.g. Steam Games"
    }

    private var createTitle: String {
        (selected != nil || manualExecutable != nil) ? "Create & Play" : "Create Empty Bottle"
    }

    private func chooseManually() {
        guard let exe = Panels.chooseFile(
            contentTypes: [UTType(filenameExtension: "exe")].compactMap { $0 },
            prompt: "Choose") else { return }
        manualExecutable = exe
        selected = nil
        if name.isEmpty { name = exe.deletingPathExtension().lastPathComponent }
    }

    private func create() {
        // The button says "Create & Play" whenever a game is chosen — so it must PLAY.
        //
        // It never did: this only appended a bottle and returned. Confirmed by creating a bottle
        // and checking processes — 0 game processes, 0 steam.exe. The label promised an action the
        // code did not contain, which is worse than a missing feature because the user waits for
        // something that is never coming.
        var createdID: Bottle.ID?

        if let game = selected {
            createdID = model.createBottle(named: name, for: game)
        } else if let exe = manualExecutable {
            // Treat a hand-picked binary as a game in whichever prefix it sits in, so it gets the
            // same bottle shape as a scanned one.
            let current = model.bottles.first { $0.id == model.selectedBottleID }
            guard let prefix = Self.prefixContaining(exe) ?? current?.url else {
                // Was a silent dismissal: no bottle, no message, nothing to act on. A binary
                // outside any prefix cannot be run by Wine, and saying so beats vanishing.
                failure = "That program isn't inside a Wine prefix, so there's nothing to run it. "
                    + "Pick a bottle first, or choose a program from inside one."
                return
            }
            createdID = model.createBottle(named: name, for: GameScanner.FoundGame(
                name: name.isEmpty ? exe.deletingPathExtension().lastPathComponent : name,
                folder: exe.deletingLastPathComponent(), executable: exe,
                sizeBytes: 0, appID: nil, prefix: prefix))
        } else {
            model.createBottle(name: name)
        }

        // Play it, if this was a "Create & Play".
        if let id = createdID, let bottle = model.bottles.first(where: { $0.id == id }) {
            model.launchSteam(in: bottle)
        }
        dismiss()
    }

    /// Walk up from an executable to the prefix root — the directory whose child is `drive_c`.
    /// A binary chosen by hand still has to belong to some prefix for Wine to run it.
    private static func prefixContaining(_ exe: URL) -> URL? {
        var dir = exe.deletingLastPathComponent()
        while dir.pathComponents.count > 1 {
            if dir.lastPathComponent == "drive_c" { return dir.deletingLastPathComponent() }
            dir = dir.deletingLastPathComponent()
        }
        return nil
    }
}
