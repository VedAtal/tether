import Combine
import Foundation

/// User settings, backed by UserDefaults. AppDelegate observes these and applies changes live.
@MainActor
final class Preferences: ObservableObject {
    static let shared = Preferences()

    @Published var traditionalWheel: Bool {
        didSet { defaults.set(traditionalWheel, forKey: Key.traditionalWheel) }
    }

    private let defaults = UserDefaults.standard

    private enum Key {
        static let traditionalWheel = "traditionalWheel"
    }

    private init() {
        defaults.register(defaults: [Key.traditionalWheel: true])
        traditionalWheel = defaults.bool(forKey: Key.traditionalWheel)
    }
}
