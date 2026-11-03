import SwiftUI
import UniformTypeIdentifiers

/// Run arbitrary Windows executables and Wine's built-in utilities inside a bottle.
struct ProgramsView: View {
    @EnvironmentObject private var model: AppModel
    let bottle: Bottle

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 12)]

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            GroupBox("Run a program") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Launch any .exe or .msi installer inside this bottle.")
                        .font(.callout).foregroundStyle(.secondary)
                    Button {
                        runExecutable()
                    } label: {
                        Label("Run EXE / MSI…", systemImage: "terminal")
                    }
                    .disabled(!bottle.isInitialized)
                }
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            GroupBox("Wine tools") {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(Wine.Tool.allCases) { tool in
                        Button {
                            model.runTool(tool, in: bottle)
                        } label: {
                            VStack(spacing: 6) {
                                Image(systemName: icon(for: tool)).font(.title2)
                                    .accessibilityHidden(true)  // the title below names the tool
                                Text(tool.title).font(.caption).multilineTextAlignment(.center)
                            }
                            .frame(maxWidth: .infinity, minHeight: 64)
                        }
                        .buttonStyle(.bordered)
                        .disabled(!bottle.isInitialized)
                    }
                }
                .padding(6)
            }
        }
        // Apple's 20pt content margin, matching Overview (docs/APPLE-GEOMETRY.md).
        .padding(20)
    }

    private func icon(for tool: Wine.Tool) -> String {
        switch tool {
        case .winecfg:  return "gearshape"
        case .regedit:  return "square.stack.3d.up"
        case .taskmgr:  return "chart.bar"
        case .control:  return "slider.horizontal.3"
        case .cmd:      return "terminal"
        case .explorer: return "folder"
        }
    }

    private func runExecutable() {
        let exeType = UTType(filenameExtension: "exe")
        let msiType = UTType(filenameExtension: "msi")
        let types = [exeType, msiType].compactMap { $0 }
        if let url = Panels.chooseFile(contentTypes: types, prompt: "Run") {
            model.runExecutable(url, in: bottle)
        }
    }
}
