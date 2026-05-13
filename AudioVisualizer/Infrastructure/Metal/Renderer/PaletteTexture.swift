import Metal
import Domain

enum PaletteFactory {
    static let xpNeon = ColorPalette(name: "XP Neon", stops: [
        RGB(r: 0.05, g: 0,   b: 0.25),
        RGB(r: 0.4,  g: 0,   b: 0.7),
        RGB(r: 0,    g: 0.7, b: 1),
        RGB(r: 0.2,  g: 1,   b: 0.5),
        RGB(r: 1,    g: 1,   b: 0.2),
        RGB(r: 1,    g: 0.3, b: 0.1)
    ])
    static let aurora = ColorPalette(name: "Aurora", stops: [
        RGB(r: 0, g: 0.05, b: 0.1), RGB(r: 0, g: 0.6, b: 0.7),
        RGB(r: 0.2, g: 1, b: 0.6), RGB(r: 0.6, g: 0.9, b: 1)
    ])
    static let sunset = ColorPalette(name: "Sunset", stops: [
        RGB(r: 0.05, g: 0, b: 0.1), RGB(r: 0.4, g: 0, b: 0.2),
        RGB(r: 1, g: 0.3, b: 0.2), RGB(r: 1, g: 0.8, b: 0.3)
    ])
    static let all = [xpNeon, aurora, sunset]

    static func texture(from palette: ColorPalette, device: MTLDevice) -> MTLTexture? {
        let n = 256
        var pixels = [UInt8](repeating: 0, count: n * 4)
        let stops = palette.stops
        for i in 0..<n {
            let t = Float(i) / Float(n - 1)
            let f = t * Float(stops.count - 1)
            let lo = Int(f.rounded(.down))
            let hi = min(stops.count - 1, lo + 1)
            let k = f - Float(lo)
            let a = stops[lo], b = stops[hi]
            let r = a.r + (b.r - a.r) * k
            let g = a.g + (b.g - a.g) * k
            let bb = a.b + (b.b - a.b) * k
            pixels[i * 4 + 0] = UInt8(max(0, min(255, r * 255)))
            pixels[i * 4 + 1] = UInt8(max(0, min(255, g * 255)))
            pixels[i * 4 + 2] = UInt8(max(0, min(255, bb * 255)))
            pixels[i * 4 + 3] = 255
        }
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: n, height: 1, mipmapped: false)
        desc.usage = [.shaderRead]
        guard let tex = device.makeTexture(descriptor: desc) else { return nil }
        tex.replace(region: MTLRegionMake2D(0, 0, n, 1), mipmapLevel: 0, withBytes: pixels, bytesPerRow: n * 4)
        return tex
    }
}
