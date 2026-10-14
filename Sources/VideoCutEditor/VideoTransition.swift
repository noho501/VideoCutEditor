import Foundation

#if canImport(AVFoundation)
@preconcurrency import AVFoundation
import CoreGraphics

public enum VideoTransition: String, CaseIterable, Sendable {
    case none = "None"
    case fade = "Fade"
    case slide = "Slide"
    case zoom = "Zoom"
    case wipe = "Wipe"
    case cube = "Cube"
    case glitch = "Glitch"
}

public struct VideoTransitionSettings: Sendable, Equatable {
    public var transition: VideoTransition
    public var duration: TimeInterval

    public init(
        transition: VideoTransition = .none,
        duration: TimeInterval = 0.5
    ) {
        self.transition = transition
        self.duration = min(max(duration, 0.1), 2)
    }
}

struct TransitionClip {
    let asset: AVAsset
    let timeRange: CMTimeRange
}

struct TransitionComposition {
    let composition: AVMutableComposition
    let videoComposition: AVMutableVideoComposition
    let audioMix: AVAudioMix?
}

enum TransitionCompositionBuilder {
    enum BuildError: LocalizedError {
        case noClips
        case missingVideoTrack
        case cannotCreateTrack

        var errorDescription: String? {
            switch self {
            case .noClips:
                return "There are no clips to compose."
            case .missingVideoTrack:
                return "A clip doesn’t contain a video track."
            case .cannotCreateTrack:
                return "The transition composition tracks couldn’t be created."
            }
        }
    }

    private struct InsertedClip {
        let videoTrack: AVMutableCompositionTrack
        let audioTrack: AVMutableCompositionTrack?
        let timelineRange: CMTimeRange
        let transform: CGAffineTransform
        let naturalSize: CGSize
    }

    static func build(
        clips: [TransitionClip],
        settings: VideoTransitionSettings
    ) async throws -> TransitionComposition {
        guard !clips.isEmpty else { throw BuildError.noClips }

        let composition = AVMutableComposition()
        let videoTracks = (0..<2).compactMap { _ in
            composition.addMutableTrack(
                withMediaType: .video,
                preferredTrackID: kCMPersistentTrackID_Invalid
            )
        }
        guard videoTracks.count == 2 else { throw BuildError.cannotCreateTrack }

        let audioTracks = (0..<2).map { _ in
            composition.addMutableTrack(
                withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid
            )
        }

        var metadata: [(track: AVAssetTrack, transform: CGAffineTransform, size: CGSize)] = []
        metadata.reserveCapacity(clips.count)
        for clip in clips {
            try Task.checkCancellation()
            guard let videoTrack = try await clip.asset.loadTracks(withMediaType: .video).first else {
                throw BuildError.missingVideoTrack
            }
            metadata.append((
                videoTrack,
                try await videoTrack.load(.preferredTransform),
                try await videoTrack.load(.naturalSize)
            ))
        }

        var overlaps = Array(repeating: CMTime.zero, count: clips.count)
        if settings.transition != .none {
            for index in 1..<clips.count {
                let previousDuration = clips[index - 1].timeRange.duration.seconds
                let currentDuration = clips[index].timeRange.duration.seconds
                let seconds = min(
                    settings.duration,
                    previousDuration * 0.5,
                    currentDuration * 0.5
                )
                overlaps[index] = CMTime(
                    seconds: max(0, seconds),
                    preferredTimescale: 600
                )
            }
        }

        var inserted: [InsertedClip] = []
        inserted.reserveCapacity(clips.count)
        var cursor = CMTime.zero

        for index in clips.indices {
            try Task.checkCancellation()
            let clip = clips[index]
            let source = metadata[index]
            let start = cursor - overlaps[index]
            let destinationVideoTrack = videoTracks[index % 2]

            try destinationVideoTrack.insertTimeRange(
                clip.timeRange,
                of: source.track,
                at: start
            )

            var destinationAudioTrack: AVMutableCompositionTrack?
            if let sourceAudioTrack = try await clip.asset.loadTracks(withMediaType: .audio).first,
               let audioTrack = audioTracks[index % 2] {
                let sourceAudioRange = try await sourceAudioTrack.load(.timeRange)
                let availableRange = CMTimeRangeGetIntersection(
                    clip.timeRange,
                    otherRange: sourceAudioRange
                )
                if !availableRange.isEmpty {
                    let offset = availableRange.start - clip.timeRange.start
                    try audioTrack.insertTimeRange(
                        availableRange,
                        of: sourceAudioTrack,
                        at: start + offset
                    )
                    destinationAudioTrack = audioTrack
                }
            }

            let timelineRange = CMTimeRange(start: start, duration: clip.timeRange.duration)
            inserted.append(InsertedClip(
                videoTrack: destinationVideoTrack,
                audioTrack: destinationAudioTrack,
                timelineRange: timelineRange,
                transform: normalizedTransform(
                    source.transform,
                    naturalSize: source.size
                ),
                naturalSize: source.size
            ))
            cursor = timelineRange.end
        }

        let first = metadata[0]
        let transformedBounds = CGRect(origin: .zero, size: first.size)
            .applying(first.transform)
            .standardized
        let renderSize = CGSize(
            width: max(2, abs(transformedBounds.width).rounded(.up)),
            height: max(2, abs(transformedBounds.height).rounded(.up))
        )

        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = renderSize
        videoComposition.frameDuration = CMTime(value: 1, timescale: 30)
        videoComposition.instructions = makeInstructions(
            inserted: inserted,
            overlaps: overlaps,
            renderSize: renderSize,
            transition: settings.transition
        )

        let audioMix = makeAudioMix(inserted: inserted, overlaps: overlaps)
        return TransitionComposition(
            composition: composition,
            videoComposition: videoComposition,
            audioMix: audioMix
        )
    }

    private static func normalizedTransform(
        _ transform: CGAffineTransform,
        naturalSize: CGSize
    ) -> CGAffineTransform {
        let rect = CGRect(origin: .zero, size: naturalSize)
            .applying(transform)
            .standardized
        return transform.concatenating(
            CGAffineTransform(translationX: -rect.minX, y: -rect.minY)
        )
    }

    private static func makeInstructions(
        inserted: [InsertedClip],
        overlaps: [CMTime],
        renderSize: CGSize,
        transition: VideoTransition
    ) -> [AVVideoCompositionInstructionProtocol] {
        var instructions: [AVVideoCompositionInstructionProtocol] = []

        for index in inserted.indices {
            let clip = inserted[index]
            let incoming = overlaps[index]
            let outgoing = index + 1 < overlaps.count ? overlaps[index + 1] : .zero
            let passStart = clip.timelineRange.start + incoming
            let passEnd = clip.timelineRange.end - outgoing

            if passEnd > passStart {
                let instruction = AVMutableVideoCompositionInstruction()
                instruction.timeRange = CMTimeRange(start: passStart, end: passEnd)
                let layer = AVMutableVideoCompositionLayerInstruction(
                    assetTrack: clip.videoTrack
                )
                layer.setTransform(clip.transform, at: passStart)
                instruction.layerInstructions = [layer]
                instructions.append(instruction)
            }

            guard index + 1 < inserted.count, outgoing > .zero else { continue }
            let next = inserted[index + 1]
            let transitionRange = CMTimeRange(
                start: next.timelineRange.start,
                duration: outgoing
            )

            if transition == .glitch {
                instructions.append(contentsOf: glitchInstructions(
                    outgoing: clip,
                    incoming: next,
                    range: transitionRange,
                    renderSize: renderSize
                ))
            } else {
                instructions.append(makeTransitionInstruction(
                    outgoing: clip,
                    incoming: next,
                    range: transitionRange,
                    renderSize: renderSize,
                    transition: transition
                ))
            }
        }

        return instructions.sorted { $0.timeRange.start < $1.timeRange.start }
    }

    private static func makeTransitionInstruction(
        outgoing: InsertedClip,
        incoming: InsertedClip,
        range: CMTimeRange,
        renderSize: CGSize,
        transition: VideoTransition
    ) -> AVMutableVideoCompositionInstruction {
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = range

        let outgoingLayer = AVMutableVideoCompositionLayerInstruction(
            assetTrack: outgoing.videoTrack
        )
        let incomingLayer = AVMutableVideoCompositionLayerInstruction(
            assetTrack: incoming.videoTrack
        )
        let end = range.end

        outgoingLayer.setTransform(outgoing.transform, at: range.start)
        incomingLayer.setTransform(incoming.transform, at: range.start)

        switch transition {
        case .none:
            break
        case .fade:
            outgoingLayer.setOpacityRamp(
                fromStartOpacity: 1,
                toEndOpacity: 0,
                timeRange: range
            )
            incomingLayer.setOpacityRamp(
                fromStartOpacity: 0,
                toEndOpacity: 1,
                timeRange: range
            )
        case .slide:
            let outgoingEnd = outgoing.transform.concatenating(
                CGAffineTransform(translationX: -renderSize.width, y: 0)
            )
            let incomingStart = incoming.transform.concatenating(
                CGAffineTransform(translationX: renderSize.width, y: 0)
            )
            outgoingLayer.setTransformRamp(
                fromStart: outgoing.transform,
                toEnd: outgoingEnd,
                timeRange: range
            )
            incomingLayer.setTransformRamp(
                fromStart: incomingStart,
                toEnd: incoming.transform,
                timeRange: range
            )
        case .zoom:
            outgoingLayer.setTransformRamp(
                fromStart: outgoing.transform,
                toEnd: scaled(outgoing.transform, scale: 1.18, size: renderSize),
                timeRange: range
            )
            outgoingLayer.setOpacityRamp(
                fromStartOpacity: 1,
                toEndOpacity: 0,
                timeRange: range
            )
            incomingLayer.setTransformRamp(
                fromStart: scaled(incoming.transform, scale: 0.82, size: renderSize),
                toEnd: incoming.transform,
                timeRange: range
            )
            incomingLayer.setOpacityRamp(
                fromStartOpacity: 0,
                toEndOpacity: 1,
                timeRange: range
            )
        case .wipe:
            incomingLayer.setCropRectangleRamp(
                fromStartCropRectangle: CGRect(
                    x: 0,
                    y: 0,
                    width: 1,
                    height: renderSize.height
                ),
                toEndCropRectangle: CGRect(origin: .zero, size: renderSize),
                timeRange: range
            )
        case .cube:
            let outgoingEnd = scaled(
                outgoing.transform,
                scale: 0.72,
                size: renderSize
            ).concatenating(
                CGAffineTransform(translationX: -renderSize.width * 0.55, y: 0)
            )
            let incomingStart = scaled(
                incoming.transform,
                scale: 0.72,
                size: renderSize
            ).concatenating(
                CGAffineTransform(translationX: renderSize.width * 0.55, y: 0)
            )
            outgoingLayer.setTransformRamp(
                fromStart: outgoing.transform,
                toEnd: outgoingEnd,
                timeRange: range
            )
            incomingLayer.setTransformRamp(
                fromStart: incomingStart,
                toEnd: incoming.transform,
                timeRange: range
            )
            outgoingLayer.setOpacity(0, at: end)
        case .glitch:
            break
        }

        instruction.layerInstructions = [incomingLayer, outgoingLayer]
        return instruction
    }

    private static func glitchInstructions(
        outgoing: InsertedClip,
        incoming: InsertedClip,
        range: CMTimeRange,
        renderSize: CGSize
    ) -> [AVMutableVideoCompositionInstruction] {
        let slices = 8
        let sliceDuration = CMTimeMultiplyByRatio(
            range.duration,
            multiplier: 1,
            divisor: Int32(slices)
        )

        return (0..<slices).map { index in
            let start = range.start + CMTimeMultiply(
                sliceDuration,
                multiplier: Int32(index)
            )
            let timeRange = CMTimeRange(start: start, duration: sliceDuration)
            let progress = Float(index + 1) / Float(slices)
            let jitter = CGFloat(index.isMultiple(of: 2) ? 1 : -1)
                * renderSize.width * 0.025 * CGFloat(1 - progress)

            let outgoingLayer = AVMutableVideoCompositionLayerInstruction(
                assetTrack: outgoing.videoTrack
            )
            outgoingLayer.setTransform(
                outgoing.transform.concatenating(
                    CGAffineTransform(translationX: -jitter, y: 0)
                ),
                at: start
            )
            outgoingLayer.setOpacity(1 - progress, at: start)

            let incomingLayer = AVMutableVideoCompositionLayerInstruction(
                assetTrack: incoming.videoTrack
            )
            incomingLayer.setTransform(
                incoming.transform.concatenating(
                    CGAffineTransform(translationX: jitter, y: 0)
                ),
                at: start
            )
            incomingLayer.setOpacity(progress, at: start)

            let instruction = AVMutableVideoCompositionInstruction()
            instruction.timeRange = timeRange
            instruction.layerInstructions = [incomingLayer, outgoingLayer]
            return instruction
        }
    }

    private static func scaled(
        _ transform: CGAffineTransform,
        scale: CGFloat,
        size: CGSize
    ) -> CGAffineTransform {
        transform
            .translatedBy(x: size.width / 2, y: size.height / 2)
            .scaledBy(x: scale, y: scale)
            .translatedBy(x: -size.width / 2, y: -size.height / 2)
    }

    private static func makeAudioMix(
        inserted: [InsertedClip],
        overlaps: [CMTime]
    ) -> AVAudioMix? {
        var parametersByTrackID: [CMPersistentTrackID: AVMutableAudioMixInputParameters] = [:]

        for index in inserted.indices {
            guard let audioTrack = inserted[index].audioTrack else { continue }
            let item: AVMutableAudioMixInputParameters
            if let existing = parametersByTrackID[audioTrack.trackID] {
                item = existing
            } else {
                item = AVMutableAudioMixInputParameters(track: audioTrack)
                parametersByTrackID[audioTrack.trackID] = item
            }
            let clip = inserted[index]
            let incoming = overlaps[index]
            let outgoing = index + 1 < overlaps.count ? overlaps[index + 1] : .zero

            if incoming > .zero {
                item.setVolumeRamp(
                    fromStartVolume: 0,
                    toEndVolume: 1,
                    timeRange: CMTimeRange(
                        start: clip.timelineRange.start,
                        duration: incoming
                    )
                )
            } else {
                item.setVolume(1, at: clip.timelineRange.start)
            }

            if outgoing > .zero {
                item.setVolumeRamp(
                    fromStartVolume: 1,
                    toEndVolume: 0,
                    timeRange: CMTimeRange(
                        start: clip.timelineRange.end - outgoing,
                        duration: outgoing
                    )
                )
            }
        }

        let parameters = Array(parametersByTrackID.values)
        guard !parameters.isEmpty else { return nil }
        let mix = AVMutableAudioMix()
        mix.inputParameters = parameters
        return mix
    }
}
#endif
