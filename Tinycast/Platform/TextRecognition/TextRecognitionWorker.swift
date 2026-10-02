import Foundation

/// Runs one `TextRecognitionHelper` per item, so Vision's allocations leave with the child process.
nonisolated enum TextRecognitionWorker {
    enum Failure: Error { case recognition, outputLimit }

    /// Mirrors `TextRecognitionExtractor.maximumTextBytes`: the helper is not in the app's module.
    private static let maximumOutputBytes = 32_000
    private static let readSize = 4096
    /// The read loop and the exit wait block, so they stay off the cooperative pool.
    private static let queue = DispatchQueue(
        label: "com.tinycast.text-recognition", qos: .background, attributes: .concurrent)

    static func extract(
        at url: URL, isPDF: Bool = false,
        executable: URL = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/TextRecognitionHelper"),
        timeout: Duration = .seconds(60)
    ) async throws -> String {
        try Task.checkCancellation()
        let process = Process()
        let output = Pipe()
        process.executableURL = executable
        process.arguments = [isPDF ? "pdf" : "image", url.path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.qualityOfService = .background
        guard let exit = try? process.runObservingExit() else { throw Failure.recognition }
        // Cancellation can land between the check above and the launch, which nothing else catches.
        if Task.isCancelled { terminate(process) }
        let deadline = Task.detached(priority: .background) {
            do { try await Task.sleep(for: timeout) } catch { return }
            terminate(process)
        }
        let result = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                queue.async {
                    continuation.resume(returning: collect(from: process, awaiting: exit, reading: output))
                }
            }
        } onCancel: {
            terminate(process)
        }
        deadline.cancel()
        try Task.checkCancellation()
        return try result.get()
    }

    /// Blocking throughout, and the only place a helper is reaped: every exit runs the `defer`.
    private static func collect(
        from process: Process, awaiting exit: ProcessExit, reading output: Pipe
    ) -> Result<String, Failure> {
        let reader = output.fileHandleForReading
        defer {
            terminate(process)
            exit.wait()
            try? reader.close()
        }
        var data = Data()
        do {
            while let chunk = try reader.read(upToCount: readSize), !chunk.isEmpty {
                data.append(chunk)
                if data.count > maximumOutputBytes { return .failure(.outputLimit) }
            }
        } catch {
            return .failure(.recognition)
        }
        exit.wait()
        guard process.terminationStatus == 0, let text = String(data: data, encoding: .utf8) else {
            return .failure(.recognition)
        }
        return .success(text)
    }

    /// `terminate()` traps on a process that never launched, so the state has to be asked first.
    private static func terminate(_ process: Process) {
        if process.isRunning { process.terminate() }
    }
}
