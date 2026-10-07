import Foundation

#if canImport(UIKit) && canImport(AVFoundation)
import UIKit
import AVFoundation

@MainActor
public final class VideoTimelineView: UIView {
    public enum Interaction: Equatable, Sendable {
        case idle
        case userScrubbing
        case draggingStartHandle
        case draggingEndHandle
    }

    public var cuts: [VideoCut] = [] {
        didSet { overlayView.cuts = cuts }
    }

    public var selectedCutIndex: Int? {
        didSet {
            overlayView.selectedIndex = selectedCutIndex
        }
    }

    public private(set) var currentTime: TimeInterval = 0
    public private(set) var pointsPerSecond: CGFloat = 24
    public private(set) var interaction: Interaction = .idle
    public let minimumPointsPerSecond: CGFloat = 6
    public let maximumPointsPerSecond: CGFloat = 96

    public var canZoomIn: Bool { pointsPerSecond < maximumPointsPerSecond }
    public var canZoomOut: Bool { pointsPerSecond > minimumPointsPerSecond }

    public var onSeekRequested: ((TimeInterval) -> Void)?
    public var onCurrentTimeChanged: ((TimeInterval) -> Void)?
    public var onScrubbingChanged: ((Bool) -> Void)?
    public var onSelectedCutChanged: ((Int) -> Void)?
    public var onSelectedCutUpdated: ((VideoCut) -> Void)?
    public var onInteractionChanged: ((Interaction) -> Void)?
    public var onZoomChanged: ((CGFloat) -> Void)?

    private let duration: TimeInterval
    private let thumbnailProvider: TimelineThumbnailProvider?
    private let scrollView = UIScrollView()
    private let contentView = UIView()
    private let thumbnailsView = UIView()
    private let overlayView = CutOverlayView()
    private let playheadView = UIView()
    private let timeBubble = UILabel()

    private let thumbnailWidth: CGFloat = 72
    private var thumbnailViews: [Int: UIImageView] = [:]
    private var thumbnailTasks: [Int: Task<Void, Never>] = [:]
    private var timelineSpace = TimelineCoordinateSpace(duration: 1, pointsPerSecond: 24, viewportWidth: 1)
    private var isApplyingProgrammaticOffset = false
    private var hasPerformedInitialLayout = false

    public init(asset: AVAsset) {
        duration = max(CMTimeGetSeconds(asset.duration), 0.1)
        thumbnailProvider = (asset as? AVURLAsset).map { TimelineThumbnailProvider(assetURL: $0.url) }
        super.init(frame: .zero)
        setupUI()
        configureOverlay()
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        thumbnailTasks.values.forEach { $0.cancel() }
    }

    public override func layoutSubviews() {
        super.layoutSubviews()

        let previousViewportWidth = timelineSpace.viewportWidth
        timelineSpace = TimelineCoordinateSpace(
            duration: duration,
            pointsPerSecond: pointsPerSecond,
            viewportWidth: bounds.width
        )

        timeBubble.frame = CGRect(x: bounds.midX - 40, y: 0, width: 80, height: 24)
        let trackFrame = CGRect(x: 0, y: 28, width: bounds.width, height: max(36, bounds.height - 28))
        scrollView.frame = trackFrame
        scrollView.contentInset = UIEdgeInsets(
            top: 0,
            left: timelineSpace.horizontalInset,
            bottom: 0,
            right: timelineSpace.horizontalInset
        )
        scrollView.scrollIndicatorInsets = scrollView.contentInset

        contentView.frame = CGRect(x: 0, y: 0, width: timelineSpace.contentWidth, height: trackFrame.height)
        thumbnailsView.frame = contentView.bounds
        overlayView.frame = contentView.bounds
        scrollView.contentSize = contentView.bounds.size

        playheadView.frame = CGRect(x: bounds.midX - 1, y: 24, width: 2, height: trackFrame.height + 4)

        if !hasPerformedInitialLayout || previousViewportWidth != bounds.width {
            hasPerformedInitialLayout = true
            setCurrentTime(currentTime, animated: false)
        }
        updateVisibleThumbnails()
    }

    public func setCurrentTime(_ time: TimeInterval, animated: Bool = false) {
        currentTime = timelineSpace.clamped(time)
        updateTimeBubble()
        guard bounds.width > 0 else { return }

        isApplyingProgrammaticOffset = true
        scrollView.setContentOffset(
            CGPoint(x: timelineSpace.contentOffset(for: currentTime), y: 0),
            animated: animated
        )
        if !animated {
            isApplyingProgrammaticOffset = false
        }
        updateVisibleThumbnails()
    }

    public func updatePlayhead(currentTime: TimeInterval) {
        guard interaction == .idle else { return }
        setCurrentTime(currentTime, animated: false)
    }

    public func zoomIn() {
        setPointsPerSecond(min(maximumPointsPerSecond, pointsPerSecond * 1.5))
    }

    public func zoomOut() {
        setPointsPerSecond(max(minimumPointsPerSecond, pointsPerSecond / 1.5))
    }

    public func scrollToCut(index: Int, animated: Bool) {
        guard cuts.indices.contains(index) else { return }
        selectedCutIndex = index
        setCurrentTime(cuts[index].startTime, animated: animated)
    }

    public func updateCut(at index: Int, with cut: VideoCut) {
        guard cuts.indices.contains(index) else { return }
        cuts[index] = cut
        overlayView.cuts = cuts
    }

    public func coordinateInteractivePopGesture(_ gestureRecognizer: UIGestureRecognizer?) {
        guard let gestureRecognizer else { return }
        gestureRecognizer.require(toFail: overlayView.startHandlePanGesture)
        gestureRecognizer.require(toFail: overlayView.endHandlePanGesture)
    }

    public func cancelThumbnailLoading() {
        thumbnailTasks.values.forEach { $0.cancel() }
        thumbnailTasks.removeAll()
        thumbnailViews.values.forEach { $0.removeFromSuperview() }
        thumbnailViews.removeAll()
        Task { await thumbnailProvider?.cancelPendingRequests() }
        setNeedsLayout()
    }

    private func setupUI() {
        backgroundColor = .clear
        clipsToBounds = false

        scrollView.delegate = self
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.alwaysBounceHorizontal = true
        scrollView.alwaysBounceVertical = false
        scrollView.isDirectionalLockEnabled = true
        scrollView.decelerationRate = .fast
        scrollView.scrollsToTop = false
        scrollView.accessibilityIdentifier = "videoCut.timeline.scroll"
        addSubview(scrollView)

        scrollView.addSubview(contentView)
        contentView.addSubview(thumbnailsView)
        contentView.addSubview(overlayView)

        playheadView.backgroundColor = .white
        playheadView.layer.shadowColor = UIColor.black.cgColor
        playheadView.layer.shadowOpacity = 0.5
        playheadView.layer.shadowRadius = 2
        playheadView.isUserInteractionEnabled = false
        addSubview(playheadView)

        timeBubble.backgroundColor = UIColor.secondarySystemBackground.withAlphaComponent(0.96)
        timeBubble.textColor = .label
        timeBubble.font = UIFontMetrics(forTextStyle: .caption1).scaledFont(
            for: .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        )
        timeBubble.textAlignment = .center
        timeBubble.layer.cornerRadius = 7
        timeBubble.layer.borderWidth = 1
        timeBubble.layer.borderColor = UIColor.separator.cgColor
        timeBubble.clipsToBounds = true
        timeBubble.adjustsFontForContentSizeCategory = true
        timeBubble.isAccessibilityElement = true
        addSubview(timeBubble)

        scrollView.panGestureRecognizer.require(toFail: overlayView.startHandlePanGesture)
        scrollView.panGestureRecognizer.require(toFail: overlayView.endHandlePanGesture)

        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        addGestureRecognizer(pinch)
        updateTimeBubble()
    }

    private func configureOverlay() {
        overlayView.duration = duration
        overlayView.pointsPerSecond = pointsPerSecond
        overlayView.onSelectCut = { [weak self] index in
            self?.selectedCutIndex = index
            self?.onSelectedCutChanged?(index)
        }
        overlayView.onUpdateSelectedCut = { [weak self] cut, handle in
            guard let self else { return }
            self.onSelectedCutUpdated?(cut)
            let time = handle == .start ? cut.startTime : cut.endTime
            self.currentTime = time
            self.updateTimeBubble()
            self.onCurrentTimeChanged?(time)
            self.onSeekRequested?(time)
        }
        overlayView.onHandleDragStateChanged = { [weak self] handle, isDragging in
            guard let self else { return }
            self.interaction = isDragging
                ? (handle == .start ? .draggingStartHandle : .draggingEndHandle)
                : .idle
            self.onInteractionChanged?(self.interaction)
        }
    }

    private func setPointsPerSecond(_ value: CGFloat) {
        let preservedTime = currentTime
        pointsPerSecond = min(max(value, minimumPointsPerSecond), maximumPointsPerSecond)
        overlayView.pointsPerSecond = pointsPerSecond
        timelineSpace = TimelineCoordinateSpace(
            duration: duration,
            pointsPerSecond: pointsPerSecond,
            viewportWidth: bounds.width
        )

        thumbnailTasks.values.forEach { $0.cancel() }
        thumbnailTasks.removeAll()
        thumbnailViews.values.forEach { $0.removeFromSuperview() }
        thumbnailViews.removeAll()

        setNeedsLayout()
        layoutIfNeeded()
        setCurrentTime(preservedTime, animated: false)
        onZoomChanged?(pointsPerSecond)
    }

    @objc private func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
        guard recognizer.state == .changed else { return }
        let value = pointsPerSecond * recognizer.scale
        recognizer.scale = 1
        setPointsPerSecond(value)
    }

    private func updateTimeBubble() {
        let minutes = Int(currentTime) / 60
        let seconds = currentTime.truncatingRemainder(dividingBy: 60)
        timeBubble.text = String(format: "%02d:%04.1f", minutes, seconds)
        timeBubble.accessibilityLabel = "Current time"
        timeBubble.accessibilityValue = timeBubble.text
    }

    private func updateVisibleThumbnails() {
        guard scrollView.bounds.width > 0, timelineSpace.contentWidth > 0 else { return }

        let visibleMinX = max(0, scrollView.contentOffset.x)
        let visibleMaxX = min(
            timelineSpace.contentWidth,
            scrollView.contentOffset.x + scrollView.bounds.width
        )
        let firstIndex = max(0, Int(floor(visibleMinX / thumbnailWidth)) - 2)
        let lastIndex = max(firstIndex, Int(ceil(visibleMaxX / thumbnailWidth)) + 2)
        let neededIndices = Set(firstIndex...lastIndex)

        for (index, imageView) in thumbnailViews where !neededIndices.contains(index) {
            imageView.removeFromSuperview()
            thumbnailViews[index] = nil
            thumbnailTasks[index]?.cancel()
            thumbnailTasks[index] = nil
        }

        for index in neededIndices where thumbnailViews[index] == nil {
            let x = CGFloat(index) * thumbnailWidth
            guard x < timelineSpace.contentWidth else { continue }

            let imageView = UIImageView(frame: CGRect(
                x: x,
                y: 0,
                width: min(thumbnailWidth, timelineSpace.contentWidth - x),
                height: thumbnailsView.bounds.height
            ))
            imageView.contentMode = .scaleAspectFill
            imageView.clipsToBounds = true
            imageView.backgroundColor = .tertiarySystemFill
            thumbnailsView.addSubview(imageView)
            thumbnailViews[index] = imageView

            let time = timelineSpace.time(forXPosition: x + thumbnailWidth / 2)
            let cacheKey = Int((time * 10).rounded())
            thumbnailTasks[index] = Task { [weak self, weak imageView] in
                guard let self else { return }
                let image = await self.thumbnailProvider?.thumbnail(at: time, cacheKey: cacheKey)
                guard !Task.isCancelled, self.thumbnailViews[index] === imageView else { return }
                imageView?.image = image
                self.thumbnailTasks[index] = nil
            }
        }
    }
}

extension VideoTimelineView: UIScrollViewDelegate {
    public func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        interaction = .userScrubbing
        onInteractionChanged?(interaction)
        onScrubbingChanged?(true)
    }

    public func scrollViewDidScroll(_ scrollView: UIScrollView) {
        updateVisibleThumbnails()
        guard !isApplyingProgrammaticOffset, interaction == .userScrubbing else { return }

        currentTime = timelineSpace.time(forContentOffset: scrollView.contentOffset.x)
        updateTimeBubble()
        onCurrentTimeChanged?(currentTime)
        onSeekRequested?(currentTime)
    }

    public func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate {
            finishScrubbing()
        }
    }

    public func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        finishScrubbing()
    }

    public func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        isApplyingProgrammaticOffset = false
    }

    private func finishScrubbing() {
        currentTime = timelineSpace.time(forContentOffset: scrollView.contentOffset.x)
        interaction = .idle
        onInteractionChanged?(interaction)
        onCurrentTimeChanged?(currentTime)
        onSeekRequested?(currentTime)
        onScrubbingChanged?(false)
    }
}
#endif
