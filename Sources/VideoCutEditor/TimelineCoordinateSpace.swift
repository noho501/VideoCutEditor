import Foundation
import CoreGraphics

struct TimelineCoordinateSpace: Equatable, Sendable {
    let duration: TimeInterval
    let pointsPerSecond: CGFloat
    let viewportWidth: CGFloat

    var contentWidth: CGFloat {
        max(1, CGFloat(max(0, duration)) * pointsPerSecond)
    }

    var horizontalInset: CGFloat {
        max(0, viewportWidth / 2)
    }

    func xPosition(for time: TimeInterval) -> CGFloat {
        CGFloat(clamped(time)) * pointsPerSecond
    }

    func time(forXPosition xPosition: CGFloat) -> TimeInterval {
        clamped(TimeInterval(xPosition / max(pointsPerSecond, 0.001)))
    }

    func contentOffset(for time: TimeInterval) -> CGFloat {
        xPosition(for: time) - horizontalInset
    }

    func time(forContentOffset contentOffset: CGFloat) -> TimeInterval {
        time(forXPosition: contentOffset + horizontalInset)
    }

    func clamped(_ time: TimeInterval) -> TimeInterval {
        min(max(time.isFinite ? time : 0, 0), max(duration, 0))
    }
}
