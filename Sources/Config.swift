import Foundation

/// User settings from `defaults` (domain com.jayden.pressure). Read on every menu open,
/// so `defaults write` takes effect without relaunching.
enum Config {
    static let defaultTopN = 5

    static var topN: Int {
        let n = UserDefaults.standard.integer(forKey: "topN")
        return n > 0 ? n : defaultTopN
    }
}
