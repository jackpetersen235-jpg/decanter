import SwiftUI

/// A live log sheet for a running operation. Auto-scrolls and offers cancel/close.
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
                .onChange(of: console.text) { _, _ in
                    withAnimation { proxy.scrollTo("log", anchor: .bottom) }
                }
            }
            .background(Color(nsColor: .textBackgroundColor))

            Divider()
            HStack {
                Spacer()
                if console.isRunning {
                    Button("Cancel", role: .destructive) { console.cancel() }
                }
                Button(console.isRunning ? "Hide" : "Close") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 640, height: 460)
    }
}
