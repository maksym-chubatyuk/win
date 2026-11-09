import UIKit

/// The size of the Windows screen programs run on. Wine reports it as the display's
/// resolution, and Madeira lists no display mode larger than it, so a game that follows
/// the Windows resolution or picks from the mode list renders at this size. A game with
/// its own resolution setting can still go higher; that setting is the game's.
struct ScreenResolution: Hashable, Identifiable {
    let width: Int
    let height: Int

    var id: String { storageValue }
    var storageValue: String { "\(width)x\(height)" }

    static let storageKey = "screenResolution"
    static let standard = ScreenResolution(width: 1280, height: 720)
    /// What programs start at until another size is picked.
    static var defaultChoice: ScreenResolution { fullScreen }

    /// 720 lines at the phone's own shape, so a game fills the screen without black bars.
    /// The width is rounded to a multiple of 8, which GPUs and video modes prefer.
    static var fullScreen: ScreenResolution {
        let bounds = UIScreen.main.nativeBounds
        let long = max(bounds.width, bounds.height), short = min(bounds.width, bounds.height)
        guard short > 0 else { return ScreenResolution(width: 1280, height: 720) }
        let width = Int((720 * long / short / 8).rounded()) * 8
        return ScreenResolution(width: width, height: 720)
    }

    static var choices: [ScreenResolution] {
        var list = [ScreenResolution(width: 960, height: 540), standard, fullScreen,
                    ScreenResolution(width: 1600, height: 900), ScreenResolution(width: 1920, height: 1080)]
        // On a 16:9 screen "full screen" is just 1280x720.
        list = list.reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
        return list
    }

    func label() -> String {
        switch self {
        case Self.fullScreen: "\(width) × \(height) (fills the screen, default)"
        case Self.standard: "1280 × 720"
        case ScreenResolution(width: 960, height: 540): "960 × 540 (fastest)"
        default: "\(width) × \(height)"
        }
    }

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }

    /// "1280x720" back to a size; nil for anything else.
    init?(storageValue: String) {
        let parts = storageValue.lowercased().split(separator: "x").compactMap { Int($0) }
        guard parts.count == 2, (320...7680).contains(parts[0]), (200...4320).contains(parts[1]) else { return nil }
        self.init(width: parts[0], height: parts[1])
    }

    /// The size to start the next program at: WIN_RESOLUTION from scripts/jit-run.sh if
    /// set, otherwise the one picked in the app.
    static var current: ScreenResolution {
        if let forced = ProcessInfo.processInfo.environment["WIN_RESOLUTION"].flatMap(ScreenResolution.init(storageValue:)) {
            return forced
        }
        return UserDefaults.standard.string(forKey: storageKey).flatMap(ScreenResolution.init(storageValue:)) ?? defaultChoice
    }
}
