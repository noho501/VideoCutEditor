import Foundation

public enum VideoCutValidator {
    public static func normalizedCuts(_ cuts: [VideoCut], duration: TimeInterval) -> [VideoCut] {
        guard duration.isFinite, duration > 0 else { return [] }

        let clamped = cuts.compactMap { cut -> VideoCut? in
            guard cut.startTime.isFinite, cut.endTime.isFinite else { return nil }
            let start = max(0, min(duration, cut.startTime))
            let end = max(0, min(duration, cut.endTime))
            guard end > start else { return nil }
            return VideoCut(startTime: start, endTime: end)
        }
        .sorted { $0.startTime < $1.startTime }

        guard !clamped.isEmpty else { return [] }

        var merged: [VideoCut] = []
        for cut in clamped {
            guard var last = merged.last else {
                merged.append(cut)
                continue
            }

            if cut.startTime <= last.endTime {
                last.endTime = max(last.endTime, cut.endTime)
                merged[merged.count - 1] = last
            } else {
                merged.append(cut)
            }
        }

        return merged
    }

    static func keepRanges(duration: TimeInterval, removing cuts: [VideoCut]) -> [ClosedRange<TimeInterval>] {
        let normalized = normalizedCuts(cuts, duration: duration)
        guard duration > 0 else { return [] }
        guard !normalized.isEmpty else { return [0...duration] }

        var ranges: [ClosedRange<TimeInterval>] = []
        var cursor: TimeInterval = 0

        for cut in normalized {
            if cut.startTime > cursor {
                ranges.append(cursor...cut.startTime)
            }
            cursor = max(cursor, cut.endTime)
        }

        if cursor < duration {
            ranges.append(cursor...duration)
        }

        return ranges.filter { $0.upperBound > $0.lowerBound }
    }
}
