import Foundation

struct ScreenshotItem: Identifiable, Equatable, Sendable {
    let url: URL
    let fileIdentity: String
    let revision: String
    let createdAt: Date
    let dateLabel: String
    let byteCount: Int64
    let pixelWidth: Int
    let pixelHeight: Int

    var id: String { url.path }
    var name: String { url.lastPathComponent }

    static func newestFirst(_ left: Self, _ right: Self) -> Bool {
        if left.createdAt != right.createdAt { return left.createdAt > right.createdAt }
        return left.id < right.id
    }

    func matchesMetadata(_ term: String) -> Bool {
        name.localizedStandardContains(term) || dateLabel.localizedStandardContains(term)
    }
}
