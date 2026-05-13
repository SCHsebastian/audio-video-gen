import Metal

enum MetalSetup {
    static func device() throws -> MTLDevice {
        guard let d = MTLCreateSystemDefaultDevice() else { throw NSError(domain: "metal", code: 1) }
        return d
    }
}
