import SwiftUI

/// The confirmation sheet for "Uninstall Decanter…" — itemises everything that will be removed,
/// with real sizes, before the single destructive action can run.
///
/// docs/COMMERCIAL-READINESS.md's own suggestion: "A 'Remove Decanter and its data' flow that itemises
/// sizes before confirming." One list, real numbers, one destructive-styled button — same risk
/// posture as the existing bottle-delete confirmation (`ContentView`'s `pendingDeletion` dialog),
/// just scaled to cover everything at once instead of one bottle.
struct UninstallView: View {
    @Environment(\.dismiss) private var dismiss

    let items: [Uninstaller.Item]

    @State private var isRemoving = false
    @State private var failureMessage: String?

    private var totalBytes: Int { items.reduce(0) { $0 + $1.bytes } }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Uninstall Decanter").font(.title2.weight(.semibold))

            Text("This permanently removes everything below — installed games, save files, and "
                + "settings cannot be recovered afterward. Decanter itself is not deleted; drag "
                + "the app to the Trash separately once this finishes.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if items.isEmpty {
                Text("Nothing to remove — no Decanter data was found.")
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                List(items, id: \.label) { item in
                    HStack {
                        Text(item.label)
                        Spacer()
                        Text(human(item.bytes))
                            .foregroundStyle(.secondary)
                            .font(.system(.body, design: .monospaced))
                    }
                }
                .frame(minHeight: 220)
            }

            HStack {
                Text("Total: \(human(totalBytes))").font(.headline)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)    // Esc backs out; Remove stays click-only
                    .disabled(isRemoving)
                Button(role: .destructive) {
                    remove()
                } label: {
                    if isRemoving {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Remove Everything")
                    }
                }
                .disabled(isRemoving || items.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 480)
        .alert("Couldn't finish removing everything",
              isPresented: Binding(get: { failureMessage != nil },
                                   set: { if !$0 { failureMessage = nil } })) {
            Button("OK") { failureMessage = nil }
        } message: {
            Text(failureMessage ?? "")
        }
    }

    /// Quits the app on full success — continuing to run with your own Application Support tree
    /// just deleted is a broken state, not a usable one. Leaves the app open on partial failure
    /// so the user can see what happened and decide what to do next.
    private func remove() {
        isRemoving = true
        let failed = Uninstaller.execute()
        isRemoving = false
        if failed.isEmpty {
            NSApplication.shared.terminate(nil)
        } else {
            failureMessage = failed.joined(separator: "\n")
        }
    }

    private func human(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}
