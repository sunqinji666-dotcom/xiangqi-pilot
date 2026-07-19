import Foundation

struct AppSettings: Codable, Sendable {
    var intelligenceMode: IntelligenceMode = .fast
    var operationMode: String = "confirm"
    var thinkingMilliseconds: Int = 500
    var minimumRecognitionConfidence: Double = 0.985
    var allowsCloudImageUpload = false
    var automaticallySaveScreenshots = false
    var emergencyShortcut = "⌥⌘Esc"
    var activeProviderID: UUID?
    var providers: [ModelProviderConfiguration] = []
}

actor AppSettingsStore {
    private let defaults: UserDefaults
    private let key = "xiangqi-pilot.settings.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> AppSettings {
        guard let data = defaults.data(forKey: key),
              let settings = try? JSONDecoder().decode(AppSettings.self, from: data) else {
            return AppSettings()
        }
        return settings
    }

    func save(_ settings: AppSettings) throws {
        defaults.set(try JSONEncoder().encode(settings), forKey: key)
    }
}
