import Combine
import Foundation

/// User settings, backed by UserDefaults. AppDelegate observes these and applies changes live.
@MainActor
final class Preferences: ObservableObject {
    static let shared = Preferences()

    @Published var traditionalWheel: Bool {
        didSet { defaults.set(traditionalWheel, forKey: Key.traditionalWheel) }
    }
    @Published var brightnessKeys: Bool {
        didSet { defaults.set(brightnessKeys, forKey: Key.brightnessKeys) }
    }
    /// The screensaver's scene, by name.
    @Published var saverScene: String {
        didSet { defaults.set(saverScene, forKey: Key.saverScene) }
    }
    /// How long the screensaver runs, in minutes. 0 runs it until stopped.
    @Published var saverMinutes: Int {
        didSet { defaults.set(saverMinutes, forKey: Key.saverMinutes) }
    }
    /// Whether the Mac locks when the screensaver ends.
    @Published var saverLocks: Bool {
        didSet { defaults.set(saverLocks, forKey: Key.saverLocks) }
    }

    /// Whether any setting has Tether change or swallow input events.
    var usesEvents: Bool { traditionalWheel || brightnessKeys }

    private let defaults = UserDefaults.standard

    private enum Key {
        static let traditionalWheel = "traditionalWheel"
        static let brightnessKeys = "brightnessKeys"
        static let saverScene = "saverScene"
        static let saverMinutes = "saverMinutes"
        static let saverLocks = "saverLocks"
    }

    private init() {
        defaults.register(defaults: [
            Key.traditionalWheel: true, Key.brightnessKeys: true, Key.saverScene: SaverScene.all[0].name, Key.saverMinutes: 0,
            Key.saverLocks: true,
        ])
        traditionalWheel = defaults.bool(forKey: Key.traditionalWheel)
        brightnessKeys = defaults.bool(forKey: Key.brightnessKeys)
        saverScene = defaults.string(forKey: Key.saverScene) ?? SaverScene.all[0].name
        saverMinutes = defaults.integer(forKey: Key.saverMinutes)
        saverLocks = defaults.bool(forKey: Key.saverLocks)
    }
}
