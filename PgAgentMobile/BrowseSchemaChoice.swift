import Foundation

/// Which schema Browse opens on. Most databases have one interesting schema,
/// usually `public`; start there instead of making people pick.
enum BrowseSchemaChoice {
    static func initial(from schemas: [String]) -> String? {
        if schemas.contains("public") { return "public" }
        return schemas.min { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// Keep `current` while it still exists, otherwise fall back to `initial`.
    static func resolve(current: String?, available schemas: [String]) -> String? {
        if let current, schemas.contains(current) { return current }
        return initial(from: schemas)
    }
}
