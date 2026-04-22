import Foundation

final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    @Published var islandEnabled: Bool {
        didSet { defaults.set(islandEnabled, forKey: Keys.islandEnabled) }
    }

    @Published var islandAutoExpand: Bool {
        didSet { defaults.set(islandAutoExpand, forKey: Keys.islandAutoExpand) }
    }

    @Published var islandPlaySound: Bool {
        didSet { defaults.set(islandPlaySound, forKey: Keys.islandPlaySound) }
    }

    @Published var islandShowOnNonNotchedDisplays: Bool {
        didSet { defaults.set(islandShowOnNonNotchedDisplays, forKey: Keys.islandShowOnNonNotchedDisplays) }
    }

    private let defaults: UserDefaults

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.islandEnabled = defaults.object(forKey: Keys.islandEnabled) as? Bool ?? true
        self.islandAutoExpand = defaults.object(forKey: Keys.islandAutoExpand) as? Bool ?? true
        self.islandPlaySound = defaults.object(forKey: Keys.islandPlaySound) as? Bool ?? true
        self.islandShowOnNonNotchedDisplays = defaults.object(forKey: Keys.islandShowOnNonNotchedDisplays) as? Bool ?? true
    }

    private enum Keys {
        static let islandEnabled = "settings.islandEnabled"
        static let islandAutoExpand = "settings.islandAutoExpand"
        static let islandPlaySound = "settings.islandPlaySound"
        static let islandShowOnNonNotchedDisplays = "settings.islandShowOnNonNotchedDisplays"
    }
}
