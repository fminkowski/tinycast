import ScreenCaptureKit
import UniformTypeIdentifiers

nonisolated enum ScreenshotCaptureService {
    static func capture(rectangle: CGRect, scale: CGFloat) async throws -> Data {
        let configuration = configuration()
        configuration.width = Int((rectangle.width * scale).rounded(.up))
        configuration.height = Int((rectangle.height * scale).rounded(.up))
        let output = try await SCScreenshotManager.captureScreenshot(rect: rectangle, configuration: configuration)
        return try await encode(output)
    }

    @MainActor
    static func capture(window: SCWindow) async throws -> Data {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let output = try await SCScreenshotManager.captureScreenshot(
            contentFilter: filter, configuration: configuration())
        return try await encode(output)
    }

    private static func configuration() -> SCScreenshotConfiguration {
        let configuration = SCScreenshotConfiguration()
        configuration.showsCursor = false
        configuration.ignoreShadows = false
        configuration.dynamicRange = .sdr
        configuration.contentType = UTType.png as UTTypeReference
        return configuration
    }

    private static func encode(_ output: SCScreenshotOutput) async throws -> Data {
        guard let image = output.sdrImage else { throw CocoaError(.fileReadCorruptFile) }
        return try await Task.detached(priority: .userInitiated) {
            try ScreenshotRepository.png(image)
        }.value
    }
}
