import AppKit
import UniformTypeIdentifiers

/// Small helpers around `NSOpenPanel` so views stay declarative.
@MainActor
enum Panels {
    /// Prompt for a directory (used when pointing the app at a Wine `bin` folder).
    static func chooseDirectory(prompt: String = "Choose") -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = prompt
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// Prompt for a single file, optionally constrained to `.exe` / `.msi`.
    static func chooseFile(contentTypes: [UTType] = [], prompt: String = "Open") -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        if !contentTypes.isEmpty { panel.allowedContentTypes = contentTypes }
        panel.prompt = prompt
        return panel.runModal() == .OK ? panel.url : nil
    }
}
