public struct HostTime: Equatable, Hashable, Sendable {
    public let machAbsolute: UInt64
    public init(machAbsolute: UInt64) { self.machAbsolute = machAbsolute }
    public static let zero = HostTime(machAbsolute: 0)
}
