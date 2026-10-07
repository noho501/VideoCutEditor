import Foundation

public struct VideoCut: Hashable, Sendable {
    public var startTime: TimeInterval
    public var endTime: TimeInterval

    public init(startTime: TimeInterval, endTime: TimeInterval) {
        self.startTime = startTime
        self.endTime = endTime
    }
}
