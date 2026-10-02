import Foundation
import ImageIO
import UniformTypeIdentifiers

nonisolated enum ScreenshotRepository {
    enum Failure: LocalizedError {
        case imageTooLarge
        var errorDescription: String? { "This image is too large to copy safely." }
    }
    private static let maximumDecodedBytes = 32 * 1024 * 1024
    private static let maximumPNGBytes = 64 * 1024 * 1024
    static func folder(chosen: String?, home: URL, bundleID: String) -> URL {
        if let chosen, AppPaths.isFolderPath(chosen) {
            let path = chosen.hasPrefix("~/") ? home.appending(path: String(chosen.dropFirst(2))).path : chosen
            return URL(filePath: path, directoryHint: .isDirectory)
                .resolvingSymlinksInPath()
        }
        let name: String
        switch bundleID {
        case "com.tinycast.app": name = "Tinycast Screenshots"
        case "com.tinycast.app.dev": name = "Tinycast Dev Screenshots"
        default: name = "Tinycast Screenshots (\(bundleID))"
        }
        return home.appending(path: "Pictures", directoryHint: .isDirectory)
            .appending(path: name, directoryHint: .isDirectory)
    }

    static func scan(_ folder: URL) throws -> [ScreenshotItem] {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory) else { return [] }
        guard isDirectory.boolValue else { throw CocoaError(.fileReadUnknown) }
        let supported = Set(CGImageSourceCopyTypeIdentifiers() as? [String] ?? [])
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey, .isSymbolicLinkKey, .creationDateKey, .contentModificationDateKey,
            .fileSizeKey, .fileResourceIdentifierKey
        ]
        let urls = try FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles])
        var items: [ScreenshotItem] = []
        for url in urls {
            try Task.checkCancellation()
            guard let type = UTType(filenameExtension: url.pathExtension), supported.contains(type.identifier),
                let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true,
                values.isSymbolicLink != true
            else { continue }
            let modified = values.contentModificationDate ?? .distantPast
            let created = values.creationDate ?? modified
            let size = values.fileSize ?? 0
            let identity = values.fileResourceIdentifier.map { String(describing: $0) } ?? url.path
            let revision = "\(identity)#\(modified.timeIntervalSince1970)#\(size)"
            let dimensions = pixelSize(url)
            items.append(ScreenshotItem(
                url: url, fileIdentity: identity, revision: revision, createdAt: created,
                dateLabel: created.formatted(date: .abbreviated, time: .shortened),
                byteCount: Int64(size), pixelWidth: dimensions.width, pixelHeight: dimensions.height))
        }
        return items.sorted(by: ScreenshotItem.newestFirst)
    }

    static func png(at url: URL) throws -> Data {
        try Task.checkCancellation()
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            CGImageSourceGetStatus(source) == .statusComplete,
            CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete,
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? Int,
            let height = properties[kCGImagePropertyPixelHeight] as? Int, width > 0, height > 0
        else { throw CocoaError(.fileReadCorruptFile) }
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        if CGImageSourceGetType(source) as String? == UTType.png.identifier, orientation == 1 {
            let bytes = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard bytes <= maximumPNGBytes else { throw Failure.imageTooLarge }
            return try Data(contentsOf: url, options: .mappedIfSafe)
        }
        guard height <= maximumDecodedBytes / 4, width <= maximumDecodedBytes / 4 / height
        else { throw Failure.imageTooLarge }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(width, height),
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { throw CocoaError(.fileReadCorruptFile) }
        try Task.checkCancellation()
        return try png(image)
    }

    static func png(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)
        else { throw CocoaError(.fileWriteUnknown) }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        return data as Data
    }

    static func save(_ png: Data, in folder: URL, at date: Date, identifier: UUID) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: ScreenshotNaming.filename(
            at: date, calendar: .current, identifier: identifier))
        let staging = folder.appending(path: ".screenshot-\(UUID()).png")
        defer { try? FileManager.default.removeItem(at: staging) }
        try png.write(to: staging, options: .atomic)
        try FileManager.default.moveItem(at: staging, to: url)
        return url
    }

    private static func pixelSize(_ url: URL) -> (width: Int, height: Int) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let values = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return (0, 0) }
        let width = values[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = values[kCGImagePropertyPixelHeight] as? Int ?? 0
        let orientation = values[kCGImagePropertyOrientation] as? Int ?? 1
        return (5...8).contains(orientation) ? (height, width) : (width, height)
    }
}
