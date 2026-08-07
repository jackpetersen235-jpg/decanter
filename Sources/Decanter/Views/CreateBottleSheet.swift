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
        .task {
            // Off the main actor: this walks thousands of files and would otherwise freeze the
            // sheet as it opens.
            let games = await Task.detached(priority: .userInitiated) { [model] in
                await model.scanForGames()
            }.value
            found = games
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
        if let game = selected {
            model.createBottle(named: name, for: game)
        } else if let exe = manualExecutable {
            // Treat a hand-picked binary as a game in whichever prefix it sits in, so it gets the
            // same bottle shape — and the same generated launcher — as a scanned one.
            let current = model.bottles.first { $0.id == model.selectedBottleID }
            let prefix = Self.prefixContaining(exe) ?? current?.url
            if let prefix {
                model.createBottle(named: name, for: GameScanner.FoundGame(
                    name: name.isEmpty ? exe.deletingPathExtension().lastPathComponent : name,
                    folder: exe.deletingLastPathComponent(), executable: exe,
                    sizeBytes: 0, appID: nil, prefix: prefix))
            }
        } else {
            model.createBottle(name: name)
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
