public enum Language: String, CaseIterable, Sendable, Equatable {
    case system, en, es

    public var displayName: String {
        switch self {
        case .system: return "System default"
        case .en:     return "English"
        case .es:     return "Español"
        }
    }
}
