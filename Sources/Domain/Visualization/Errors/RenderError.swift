public enum RenderError: Error, Equatable, Sendable {
    case metalDeviceUnavailable
    case shaderCompilationFailed(name: String)
    case pipelineCreationFailed(name: String)
}
