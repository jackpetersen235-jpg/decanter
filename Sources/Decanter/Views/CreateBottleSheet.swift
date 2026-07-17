import SwiftUI

struct CreateBottleSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var name: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Bottle").font(.title2.bold())

            Text("A bottle is an isolated Windows environment (a Wine prefix). "
                 + "Create one per game or launcher to keep things clean.")
                .font(.callout).foregroundStyle(.secondary)

            Form {
                TextField("Name", text: $name, prompt: Text("e.g. Steam Games"))
                LabeledContent("Wine build") {
                    Text(model.defaultInstallation?.name ?? "None")
                        .foregroundStyle(model.defaultInstallation == nil ? .red : .primary)
                }
            }
            .formStyle(.grouped)

            if model.defaultInstallation == nil {
                Label("No Wine build selected. Add one in Setup first.", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Create") {
                    model.createBottle(name: name)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(model.defaultInstallation == nil)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}
