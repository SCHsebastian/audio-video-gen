import SwiftUI
import MetalKit

struct MetalCanvas: NSViewRepresentable {
    let renderer: MTKViewDelegate

    func makeNSView(context: Context) -> MTKView {
        let v = MTKView()
        v.device = MTLCreateSystemDefaultDevice()
        v.colorPixelFormat = .bgra8Unorm_srgb
        v.preferredFramesPerSecond = 120
        v.delegate = renderer
        v.framebufferOnly = false
        return v
    }
    func updateNSView(_ nsView: MTKView, context: Context) {}
}
