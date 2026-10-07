import Foundation

enum VideoCutFormatting {
    static func shortTime(_ value: TimeInterval) -> String {
        let total = max(0, Int(value.rounded()))
        let minutes = total / 60
        let seconds = total % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}
