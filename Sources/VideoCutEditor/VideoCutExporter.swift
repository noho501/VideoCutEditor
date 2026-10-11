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

    private let merger = VideoMerger()
    private var exportTask: Task<Void, Never>?

    public init() {}

    deinit {
        exportTask?.cancel()
    }

    public func cancel() {
        exportTask?.cancel()
        merger.cancelMerge()
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
            guard let self else { return }

            var segmentURLs: [URL] = []
            defer {
                segmentURLs.forEach { VideoCutFileManager.remove($0) }
                self.exportTask = nil
            }

            do {
                progress(0)
                let asset = AVURLAsset(url: sourceURL)
                let duration = try await asset.load(.duration).seconds
                let selectedCuts = VideoCutValidator.normalizedCuts(
                    cuts,
                    duration: duration
                )
                guard !selectedCuts.isEmpty else {
                    throw ExportError.noOutputContent
                }

                let videoTracks = try await asset.loadTracks(withMediaType: .video)
                guard !videoTracks.isEmpty else {
                    throw ExportError.missingVideoTrack
                }

                for (index, cut) in selectedCuts.enumerated() {
                    try Task.checkCancellation()
                    let segmentURL = try VideoCutFileManager.makeOutputURL()
                    segmentURLs.append(segmentURL)

                    let baseProgress = Float(index) / Float(selectedCuts.count)
                    let segmentWeight = 1 / Float(selectedCuts.count)
                    try await Self.exportSegment(
                        sourceURL: sourceURL,
                        cut: cut,
                        outputURL: segmentURL
                    ) { value in
                        progress((baseProgress + value * segmentWeight) * 0.65)
                    }
                }

                try Task.checkCancellation()
                let url = try await merger.mergeVideos(
                    videoURLs: segmentURLs,
                    outputURL: outputURL
                ) { value in
                    progress(0.65 + value * 0.35)
                }

                try Task.checkCancellation()
                progress(1)
                completion(.success(url))
            } catch {
                VideoCutFileManager.remove(outputURL)
                completion(.failure(error))
            }
        }
    }

    private nonisolated static func exportSegment(
        sourceURL: URL,
        cut: VideoCut,
        outputURL: URL,
        progress: @escaping @Sendable (Float) -> Void
    ) async throws {
        let asset = AVURLAsset(url: sourceURL)
        guard let session = AVAssetExportSession(
            asset: asset,
            presetName: AVAssetExportPresetHighestQuality
        ) else {
            throw ExportError.cannotCreateExportSession
        }
        guard session.supportedFileTypes.contains(.mp4) else {
            throw ExportError.unsupportedOutputType
        }

        VideoCutFileManager.remove(outputURL)
        session.timeRange = CMTimeRange(
            start: CMTime(seconds: cut.startTime, preferredTimescale: 600),
            end: CMTime(seconds: cut.endTime, preferredTimescale: 600)
        )
        session.shouldOptimizeForNetworkUse = true

        try await export(session, to: outputURL, progress: progress)
    }

    private nonisolated static func export(
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

    private nonisolated static func legacyExport(
        _ session: AVAssetExportSession
    ) async throws {
        let box = ExportSessionBox(session)
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

private final class ExportSessionBox: @unchecked Sendable {
    let session: AVAssetExportSession

    init(_ session: AVAssetExportSession) {
        self.session = session
    }
}
#endif
