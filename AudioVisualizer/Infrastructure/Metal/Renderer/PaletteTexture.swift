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
    static let inferno = ColorPalette(name: "Inferno", stops: [
        RGB(r: 0, g: 0, b: 0.04),
        RGB(r: 0.25, g: 0.04, b: 0.30),
        RGB(r: 0.75, g: 0.12, b: 0.18),
        RGB(r: 0.99, g: 0.45, b: 0.08),
        RGB(r: 0.99, g: 0.98, b: 0.64)
    ])
    static let ocean = ColorPalette(name: "Ocean", stops: [
        RGB(r: 0.0, g: 0.05, b: 0.12),
        RGB(r: 0.0, g: 0.25, b: 0.45),
        RGB(r: 0.05, g: 0.65, b: 0.85),
        RGB(r: 0.55, g: 0.95, b: 0.85),
        RGB(r: 0.95, g: 1.0,  b: 0.95)
    ])
    static let mono = ColorPalette(name: "Mono", stops: [
        RGB(r: 0.04, g: 0.04, b: 0.06),
        RGB(r: 0.45, g: 0.48, b: 0.55),
        RGB(r: 0.92, g: 0.94, b: 0.98)
    ])
    /// Synthwave / Outrun palette. Stops chosen so the Synthwave shader's
    /// sample positions land on the iconic 80s roles: near-black ground at
    /// u=0, deep navy sky at u≈0.12, dark purple mid-sky / cool mountain rim
    /// near u≈0.22-0.35, magenta mountain fill at u≈0.50, hot pink grid neon
    /// at u≈0.65, warm pink-orange horizon at u≈0.78, orange sun upper at
    /// u≈0.90, laser-lemon sun core at u≈0.97. Hex sources: #FF2975 hot
    /// pink, #FF901F orange, #FEF65B laser lemon — the retrowave canon.
    static let synthwave = ColorPalette(name: "Synthwave", stops: [
        RGB(r: 0.008, g: 0.005, b: 0.030),   // 0: near-black ground
        RGB(r: 0.040, g: 0.045, b: 0.180),   // 1: deep navy sky
        RGB(r: 0.200, g: 0.060, b: 0.380),   // 2: deep purple
        RGB(r: 0.560, g: 0.060, b: 0.700),   // 3: magenta
        RGB(r: 1.000, g: 0.161, b: 0.459),   // 4: hot pink
        RGB(r: 1.000, g: 0.565, b: 0.122),   // 5: orange
        RGB(r: 1.000, g: 0.940, b: 0.340)    // 6: laser lemon
    ])
    static let all = [synthwave, xpNeon, aurora, sunset, inferno, ocean, mono]

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
