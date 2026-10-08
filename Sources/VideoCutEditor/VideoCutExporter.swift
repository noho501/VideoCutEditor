import Foundation

#if canImport(AVFoundation)
@preconcurrency import AVFoundation

@MainActor
public final class VideoCutExporter {
    public enum ExportError: LocalizedError {
        case missingVideoTrack
        case cannotCreateExportSession
        case noOutputContent
        case unsupportedOutputType

        public var errorDescription: String? {
            switch self {
            case .missingVideoTrack:
                return "The source video doesn’t contain a video track."
            case .cannotCreateExportSession:
                return "The export session couldn’t be created."
            case .noOutputContent:
                return "Add at least one valid cut before exporting."
            case .unsupportedOutputType:
                return "The source can’t be exported as MP4."
            }
        }
    }

    private var exportTask: Task<Void, Never>?

    public init() {}

    deinit {
        exportTask?.cancel()
    }

    public func cancel() {
        exportTask?.cancel()
        exportTask = nil
    }

    public func export(
        sourceURL: URL,
        cuts: [VideoCut],
        outputURL: URL,
        progress: @escaping @Sendable (Float) -> Void,
        completion: @escaping @Sendable (Result<URL, Error>) -> Void
    ) {
        cancel()
        exportTask = Task { [weak self] in
            do {
                progress(0)
                try await Self.performExport(
                    sourceURL: sourceURL,
                    cuts: cuts,
                    outputURL: outputURL,
                    progress: progress
                )
                try Task.checkCancellation()
                progress(1)
                completion(.success(outputURL))
            } catch {
                VideoCutFileManager.remove(outputURL)
                completion(.failure(error))
            }
            self?.exportTask = nil
        }
    }

    private nonisolated static func performExport(
        sourceURL: URL,
        cuts: [VideoCut],
        outputURL: URL,
        progress: @escaping @Sendable (Float) -> Void
    ) async throws {
        let asset = AVURLAsset(url: sourceURL)
        let durationTime = try await asset.load(.duration)
        let duration = durationTime.seconds
        let selectedRanges = VideoCutValidator.normalizedCuts(cuts, duration: duration)
        guard !selectedRanges.isEmpty else {
            throw ExportError.noOutputContent
        }

        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard let sourceVideoTrack = videoTracks.first else {
            throw ExportError.missingVideoTrack
        }
        let sourceAudioTracks = try await asset.loadTracks(withMediaType: .audio)

        let composition = AVMutableComposition()
        guard let destinationVideoTrack = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw ExportError.missingVideoTrack
        }
        let destinationAudioTracks = sourceAudioTracks.map { _ in
            composition.addMutableTrack(
                withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid
            )
        }

        var cursor = CMTime.zero
        for cut in selectedRanges {
            try Task.checkCancellation()
            let timeRange = CMTimeRange(
                start: CMTime(seconds: cut.startTime, preferredTimescale: 600),
                end: CMTime(seconds: cut.endTime, preferredTimescale: 600)
            )
            try destinationVideoTrack.insertTimeRange(
                timeRange,
                of: sourceVideoTrack,
                at: cursor
            )

            for (index, sourceAudioTrack) in sourceAudioTracks.enumerated() {
                let sourceAudioRange = try await sourceAudioTrack.load(.timeRange)
                let availableRange = CMTimeRangeGetIntersection(timeRange, otherRange: sourceAudioRange)
                guard !availableRange.isEmpty else { continue }

                let audioOffset = availableRange.start - timeRange.start
                try destinationAudioTracks[index]?.insertTimeRange(
                    availableRange,
                    of: sourceAudioTrack,
                    at: cursor + audioOffset
                )
            }
            cursor = cursor + timeRange.duration
        }

        destinationVideoTrack.preferredTransform = try await sourceVideoTrack.load(
            .preferredTransform
        )

        guard let session = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetHighestQuality
        ) else {
            throw ExportError.cannotCreateExportSession
        }
        guard session.supportedFileTypes.contains(.mp4) else {
            throw ExportError.unsupportedOutputType
        }
        session.shouldOptimizeForNetworkUse = true

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

            do {
                try await session.export(to: outputURL, as: .mp4)
                progressTask.cancel()
            } catch {
                progressTask.cancel()
                throw error
            }
        } else {
            session.outputURL = outputURL
            session.outputFileType = .mp4
            try await legacyExport(session)
        }
    }

    private nonisolated static func legacyExport(
        _ session: AVAssetExportSession
    ) async throws {
        // iOS 15 only exposes a @Sendable callback for a non-Sendable session.
        // The box is safe because this function owns the configured session and
        // reads it only after AVFoundation invokes its completion callback.
        let box = LegacyExportSessionBox(session)
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
                            throwing: box.session.error ?? ExportError.cannotCreateExportSession
                        )
                    }
                }
            }
        } onCancel: {
            box.session.cancelExport()
        }
    }
}

private final class LegacyExportSessionBox: @unchecked Sendable {
    let session: AVAssetExportSession

    init(_ session: AVAssetExportSession) {
        self.session = session
    }
}
#endif
