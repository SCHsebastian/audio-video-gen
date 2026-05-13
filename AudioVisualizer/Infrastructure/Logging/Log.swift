import os.log
import Foundation

enum Log {
    static let subsystem = "dev.audiovideogen.AudioVisualizer"
    static let capture = Logger(subsystem: subsystem, category: "capture")
    static let analysis = Logger(subsystem: subsystem, category: "analysis")
    static let render = Logger(subsystem: subsystem, category: "render")
    static let vm = Logger(subsystem: subsystem, category: "vm")
}
