import Foundation

/// User settings from `defaults` (domain com.jayden.pressure). Read on every menu open,
/// so `defaults write` takes effect without relaunching.
enum Config {
    // com.todesktop.230313mzl4w4u92 is Cursor.
    static let defaultExcludedBundleIDs = ["com.apple.Terminal", "com.mitchellh.ghostty", "com.todesktop.230313mzl4w4u92"]
    static let defaultTopN = 5

    static var excludedBundleIDs: Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: "excludedBundleIDs") ?? defaultExcludedBundleIDs)
    }

    static var topN: Int {
        let n = UserDefaults.standard.integer(forKey: "topN")
        return n > 0 ? n : defaultTopN
    }
}
