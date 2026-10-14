import Foundation

#if canImport(AVFoundation)
@preconcurrency import AVFoundation

@MainActor
final class VideoMerger {
    enum MergeError: LocalizedError {
        case insufficientDiskSpace
        case noValidVideo
        case cannotCreateExportSession
        case unsupportedOutputType

        var errorDescription: String? {
            switch self {
            case .insufficientDiskSpace:
                return "There isn’t enough free disk space to merge the selected clips."
            case .noValidVideo:
                return "There are no valid video clips to merge."
            case .cannotCreateExportSession:
                return "The merged video export session couldn’t be created."
            case .unsupportedOutputType:
                return "The merged video can’t be exported as MP4."
            }
        }
    }

    private var exportSession: AVAssetExportSession?

    func mergeVideos(
        videoURLs: [URL],
        outputURL: URL,
        transitionSettings: VideoTransitionSettings,
        progress: @escaping @Sendable (Float) -> Void
    ) async throws -> URL {
        guard !videoURLs.isEmpty else {
            throw MergeError.noValidVideo
        }
        guard hasEnoughDiskSpace(for: videoURLs) else {
            throw MergeError.insufficientDiskSpace
        }

        var clips: [TransitionClip] = []
        clips.reserveCapacity(videoURLs.count)
        for url in videoURLs {
            try Task.checkCancellation()
            let asset = AVURLAsset(url: url)
            let duration = try await asset.load(.duration)
            guard duration.isValid, duration.isNumeric, duration > .zero else { continue }
            clips.append(TransitionClip(
                asset: asset,
                timeRange: CMTimeRange(start: .zero, duration: duration)
            ))
        }
        guard !clips.isEmpty else {
            throw MergeError.noValidVideo
        }

        let result = try await TransitionCompositionBuilder.build(
            clips: clips,
            settings: transitionSettings
        )
        VideoCutFileManager.remove(outputURL)

        guard let session = AVAssetExportSession(
            asset: result.composition,
            presetName: AVAssetExportPresetHighestQuality
        ) else {
            throw MergeError.cannotCreateExportSession
        }
        guard session.supportedFileTypes.contains(.mp4) else {
            throw MergeError.unsupportedOutputType
        }

        session.videoComposition = result.videoComposition
        session.audioMix = result.audioMix
        session.shouldOptimizeForNetworkUse = true
        session.canPerformMultiplePassesOverSourceMediaData = true
        exportSession = session
        defer { exportSession = nil }

        try await export(session, to: outputURL, progress: progress)
        return outputURL
    }

    func cancelMerge() {
        exportSession?.cancelExport()
        exportSession = nil
    }

    private func hasEnoughDiskSpace(for videoURLs: [URL]) -> Bool {
        let requiredBytes = videoURLs.reduce(Int64.zero) { partialResult, url in
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
                  let fileSize = values.fileSize else {
                return partialResult
            }
            return partialResult + Int64(fileSize)
        }

        guard let values = try? VideoCutFileManager.baseDirectoryURL.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        ), let availableBytes = values.volumeAvailableCapacityForImportantUsage else {
            return true
        }

        return availableBytes > max(requiredBytes * 3 / 2, 32 * 1_024 * 1_024)
    }

    private func export(
        _ session: AVAssetExportSession,
        to outputURL: URL,
        progress: @escaping @Sendable (Float) -> Void
    ) async throws {
        if #available(iOS 18.0, *) {
            let states = session.states(updateInterval: 0.1)
            let progressTask = Task {
                for await state in states {
                    guard !Task.isCancelled else { break }
                    if case .exporting(let value) = state {
                        progress(Float(value.fractionCompleted))
                    }
                }
            }
            defer { progressTask.cancel() }
            try await session.export(to: outputURL, as: .mp4)
        } else {
            session.outputURL = outputURL
            session.outputFileType = .mp4
            try await legacyExport(session)
        }
    }

    private func legacyExport(_ session: AVAssetExportSession) async throws {
        let box = VideoMergerExportSessionBox(session)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                box.session.exportAsynchronously {
                    switch box.session.status {
                    case .completed:
                        continuation.resume()
                    case .cancelled:
                        continuation.resume(throwing: CancellationError())
                    default:
                        continuation.resume(
                            throwing: box.session.error ?? MergeError.cannotCreateExportSession
                        )
                    }
                }
            }
        } onCancel: {
            box.session.cancelExport()
        }
    }
}

private final class VideoMergerExportSessionBox: @unchecked Sendable {
    let session: AVAssetExportSession

    init(_ session: AVAssetExportSession) {
        self.session = session
    }
}
#endif
