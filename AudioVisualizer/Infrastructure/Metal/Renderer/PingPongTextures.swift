import Metal

final class PingPongTextures {
    private(set) var current: MTLTexture
    private(set) var previous: MTLTexture
    private let device: MTLDevice
    init?(device: MTLDevice, width: Int, height: Int) {
        self.device = device
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        desc.usage = [.renderTarget, .shaderRead]
        guard let a = device.makeTexture(descriptor: desc), let b = device.makeTexture(descriptor: desc) else { return nil }
        self.current = a; self.previous = b
    }
    func swap() { let t = current; current = previous; previous = t }
}
