import Foundation

#if canImport(UIKit) && canImport(AVFoundation)
import UIKit
import AVFoundation

public actor TimelineThumbnailProvider {
    private let assetURL: URL
    private let cache = NSCache<NSNumber, UIImage>()
    private let timescale: CMTimeScale = 600

    public init(assetURL: URL) {
        self.assetURL = assetURL
        cache.countLimit = 96
        cache.totalCostLimit = 24 * 1_024 * 1_024
    }

    public func thumbnail(at time: TimeInterval, cacheKey: Int? = nil) async -> UIImage? {
        guard !Task.isCancelled else { return nil }

        let key = NSNumber(value: cacheKey ?? Int((time * 10).rounded()))
        if let cached = cache.object(forKey: key) {
            return cached
        }

        let requestedTime = CMTime(seconds: max(0, time), preferredTimescale: timescale)
        let cgImage: CGImage?

        if #available(iOS 16.0, *) {
            cgImage = await Self.modernImage(at: requestedTime, assetURL: assetURL)
        } else {
            cgImage = await Self.legacyImage(at: requestedTime, assetURL: assetURL)
        }

        guard !Task.isCancelled, let cgImage else { return nil }
        let image = UIImage(cgImage: cgImage)
        cache.setObject(image, forKey: key, cost: imageCost(image))
        return image
    }

    public func cancelPendingRequests() {
        // The timeline cancels each task that scrolls out of the prefetch window.
    }

    public func clearCache() {
        cache.removeAllObjects()
    }

    @available(iOS 16.0, *)
    private nonisolated static func modernImage(
        at time: CMTime,
        assetURL: URL
    ) async -> CGImage? {
        let generator = makeGenerator(assetURL: assetURL)
        return try? await generator.image(at: time).image
    }

    private nonisolated static func legacyImage(
        at time: CMTime,
        assetURL: URL
    ) async -> CGImage? {
        let generator = makeGenerator(assetURL: assetURL)
        return await withCheckedContinuation { continuation in
            generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: time)]) {
                _, image, _, result, _ in
                continuation.resume(returning: result == .succeeded ? image : nil)
            }
        }
    }

    private nonisolated static func makeGenerator(assetURL: URL) -> AVAssetImageGenerator {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: assetURL))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 160, height: 90)
        let tolerance = CMTime(seconds: 0.25, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance
        return generator
    }

    private func imageCost(_ image: UIImage) -> Int {
        guard let cgImage = image.cgImage else { return 0 }
        return cgImage.bytesPerRow * cgImage.height
    }
}
#endif
