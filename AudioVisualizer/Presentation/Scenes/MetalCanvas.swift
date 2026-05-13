import SwiftUI
import MetalKit

struct MetalCanvas: NSViewRepresentable {
    let renderer: MTKViewDelegate
    /// Target frames per second. `0` means unlimited (defers to the display's
    /// preferred refresh rate).
    let preferredFPS: Int

    func makeNSView(context: Context) -> MTKView {
        let v = MTKView()
        v.device = MTLCreateSystemDefaultDevice()
        v.colorPixelFormat = .bgra8Unorm_srgb
        v.preferredFramesPerSecond = effectiveFPS(preferredFPS)
        v.delegate = renderer
        v.framebufferOnly = false
        return v
    }
    func updateNSView(_ nsView: MTKView, context: Context) {
        let target = effectiveFPS(preferredFPS)
        if nsView.preferredFramesPerSecond != target {
            nsView.preferredFramesPerSecond = target
        }
    }

    /// MTKView treats `preferredFramesPerSecond == 0` as "don't drive the
    /// loop", which would freeze the view. Treat user-facing "unlimited" as
    /// 120 fps (covers ProMotion displays).
    private func effectiveFPS(_ requested: Int) -> Int {
        requested <= 0 ? 120 : requested
    }
}
