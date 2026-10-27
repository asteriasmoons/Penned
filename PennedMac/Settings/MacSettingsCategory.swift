enum MacSettingsCategory: String, CaseIterable, Identifiable {
    case templates = "Templates", published = "Published Content", stats = "Stats", folders = "On-device Folders", tags = "Tags"
    case space = "Space Settings", spaces = "My Spaces", dailyNotes = "Daily Notes"
    case appearance = "Appearance & Sound", language = "Language & Spelling", security = "Security", advanced = "Advanced"
    case account = "Account Settings", subscription = "My Subscription", team = "My Team", integrations = "Integrations", assistant = "Assistant"
    case notifications = "Notifications", diagnostics = "Diagnostics", library = "Library & Sync", about = "About"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .templates: return "quote"
        case .published: return "linkcircle"
        case .stats: return "chartcircle"
        case .folders: return "openedfolder"
        case .tags: return "hashtagwavy"
        case .space: return "settings"
        case .spaces: return "spaces"
        case .dailyNotes: return "mooncal"
        case .appearance, .language: return "text"
        case .account: return "profilewavy"
        case .library: return "cloudie"
        case .about: return "infowavy"
        case .security: return "lockwavy"
        case .advanced: return "settingswavy"
        case .subscription: return "subscription"
        case .team: return "arrowsprofile"
        case .integrations: return "link"
        case .assistant: return "sparklecircle"
        case .notifications: return "bellfill"
        case .diagnostics: return "heartpulse"
        }
    }
    var requiresUnavailableService: Bool { [.published, .subscription, .team, .assistant].contains(self) }
}
