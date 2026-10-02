import Foundation

nonisolated enum ScreenshotNaming {
    static func filename(at date: Date, calendar: Calendar, identifier: UUID) -> String {
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let timestamp = String(
            format: "%04d-%02d-%02d at %02d.%02d.%02d",
            parts.year ?? 0, parts.month ?? 0, parts.day ?? 0,
            parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0)
        return "Screenshot \(timestamp) \(identifier.uuidString).png"
    }
}
