import Foundation

/// Pure edits to the bottle list, kept out of `AppModel` so they can be tested without one.
enum BottleList {

    /// The list with `bottle` put back at `index`, where it was before it was removed.
    ///
    /// For undoing "Delete Bottle (keep files)": that deletion only drops the list entry and leaves
    /// the prefix on disk, so putting the entry back is the whole undo. The index is clamped because
    /// the list may have shrunk since, and a bottle already present is left alone so a repeated
    /// undo can never duplicate it.
    static func restoring(_ bottle: Bottle, at index: Int, in bottles: [Bottle]) -> [Bottle] {
        guard !bottles.contains(where: { $0.id == bottle.id }) else { return bottles }
        let position = max(0, min(index, bottles.count))
        return Array(bottles[..<position]) + [bottle] + Array(bottles[position...])
    }
}
