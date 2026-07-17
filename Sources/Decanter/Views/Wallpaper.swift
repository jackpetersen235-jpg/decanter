import SwiftUI
import AppKit

/// The app's wallpaper image. Loaded from the .app bundle's Resources when packaged,
/// with a fallback to the repo's Assets folder so `swift run` looks right too.
enum Wallpaper {
    static let image: NSImage? = {
        if let url = Bundle.main.url(forResource: "wallpaper", withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            return image
        }
        // Dev fallback: running straight from the package directory.
        let dev = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Assets/wallpaper.png")
        return NSImage(contentsOf: dev)
    }()
}

/// Paints the wizard behind a view, faint enough to stay out of the content's way.
/// Nothing is drawn if the wallpaper file isn't present, so this is always safe.
struct WallpaperBackground: ViewModifier {
    var opacity: Double = 0.12

    func body(content: Content) -> some View {
        ZStack {
            if let image = Wallpaper.image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .opacity(opacity)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            content
        }
    }
}

extension View {
    /// Places the app wallpaper behind this view.
    func wallpaper(opacity: Double = 0.12) -> some View {
        modifier(WallpaperBackground(opacity: opacity))
    }
}
