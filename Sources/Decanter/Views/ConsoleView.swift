import SwiftUI

/// A live log sheet for a running operation. Auto-scrolls and offers stop/close.
struct ConsoleView: View {
    @ObservedObject var console: TaskConsole
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                if console.isRunning { ProgressView().controlSize(.small) }
                Text(console.title).font(.headline)
                Spacer()
            }
            .padding(12)
            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    Text(console.text.isEmpty ? "…" : console.text)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .id("log")
                }
                // Jump, don't animate: this fires on every log line, so an animated scroll kept the
                // view in motion for the whole of a long install (HIG Motion: avoid motion on
                // interactions that happen frequently), with no way for Reduce Motion to stop it.
                .onChange(of: console.text) { _, _ in
                    proxy.scrollTo("log", anchor: .bottom)
                }
            }
            .background(Color(nsColor: .textBackgroundColor))

            Divider()
            HStack {
                Spacer()
                // "Stop", not "Cancel": this kills the running operation (an engine download, a
                // Steam install), and beside "Hide" a "Cancel" read as "close this window".
                if console.isRunning {
                    Button("Stop", role: .destructive) { console.cancel() }
                }
                Button(console.isRunning ? "Hide" : "Close") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 640, height: 460)
        // Esc hides, like the button — it never stops the operation.
        .onExitCommand { dismiss() }
    }
}
