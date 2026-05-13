import TPCircularBuffer
import Foundation

final class RingBuffer {
    private var buffer = TPCircularBuffer()

    init(capacityBytes: Int) {
        let ok = _TPCircularBufferInit(&buffer, UInt32(capacityBytes),
                                       MemoryLayout<TPCircularBuffer>.size)
        precondition(ok, "TPCircularBuffer init failed")
    }
    deinit { TPCircularBufferCleanup(&buffer) }

    /// Producer side. Safe to call from the Core Audio IOProc thread.
    func write(_ src: UnsafeRawPointer, byteCount: Int) -> Bool {
        TPCircularBufferProduceBytes(&buffer, src, UInt32(byteCount))
    }

    /// Consumer side. Returns a pointer into the buffer and the number of bytes available.
    /// Caller must call `markRead(byteCount:)` once it has consumed.
    func peek() -> (pointer: UnsafeMutableRawPointer?, byteCount: Int) {
        var bytes: UInt32 = 0
        let p = TPCircularBufferTail(&buffer, &bytes)
        return (p, Int(bytes))
    }

    func markRead(byteCount: Int) {
        TPCircularBufferConsume(&buffer, UInt32(byteCount))
    }
}
