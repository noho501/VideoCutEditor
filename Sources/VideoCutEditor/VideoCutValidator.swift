import Foundation

public enum VideoCutValidator {
    public static func clampedCuts(_ cuts: [VideoCut], duration: TimeInterval) -> [VideoCut] {
        guard duration.isFinite, duration > 0 else { return [] }

        return cuts.compactMap { cut -> VideoCut? in
            guard cut.startTime.isFinite, cut.endTime.isFinite else { return nil }
            let start = max(0, min(duration, cut.startTime))
            let end = max(0, min(duration, cut.endTime))
            guard end > start else { return nil }
            return VideoCut(startTime: start, endTime: end)
        }
    }

    public static func normalizedCuts(_ cuts: [VideoCut], duration: TimeInterval) -> [VideoCut] {
        let clamped = clampedCuts(cuts, duration: duration)
            .sorted {
                if $0.startTime == $1.startTime {
                    return $0.endTime < $1.endTime
                }
                return $0.startTime < $1.startTime
            }

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
}
