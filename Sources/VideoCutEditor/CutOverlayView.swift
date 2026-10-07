import Foundation

#if canImport(UIKit)
import UIKit

@MainActor
final class CutOverlayView: UIView, UIGestureRecognizerDelegate {
    enum Handle: Sendable {
        case start
        case end
    }

    var cuts: [VideoCut] = [] {
        didSet { setNeedsLayout() }
    }
    var duration: TimeInterval = 1 {
        didSet { setNeedsLayout() }
    }
    var pointsPerSecond: CGFloat = 24 {
        didSet { setNeedsLayout() }
    }
    var selectedIndex: Int? {
        didSet { setNeedsLayout() }
    }

    var onSelectCut: ((Int) -> Void)?
    var onUpdateSelectedCut: ((VideoCut, Handle) -> Void)?
    var onHandleDragStateChanged: ((Handle, Bool) -> Void)?

    let startHandlePanGesture = UIPanGestureRecognizer()
    let endHandlePanGesture = UIPanGestureRecognizer()

    private let overlayColor = UIColor.systemYellow.withAlphaComponent(0.34)
    private let selectedOverlayColor = UIColor.systemYellow.withAlphaComponent(0.48)
    private var cutLayers: [CAShapeLayer] = []
    private let startHandle = HandleView()
    private let endHandle = HandleView()
    private var activeHandle: Handle?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = true
        accessibilityIdentifier = "videoCut.timeline.overlay"

        [startHandle, endHandle].forEach {
            $0.isHidden = true
            addSubview($0)
        }

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        addGestureRecognizer(tap)

        startHandlePanGesture.addTarget(self, action: #selector(handleStartPan(_:)))
        endHandlePanGesture.addTarget(self, action: #selector(handleEndPan(_:)))
        startHandlePanGesture.delegate = self
        endHandlePanGesture.delegate = self
        startHandle.addGestureRecognizer(startHandlePanGesture)
        endHandle.addGestureRecognizer(endHandlePanGesture)
    }

    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        synchronizeLayers()

        for (index, cut) in cuts.enumerated() {
            let cutFrame = frame(for: cut)
            let path = UIBezierPath(roundedRect: cutFrame, cornerRadius: 5)
            let layer = cutLayers[index]
            layer.path = path.cgPath
            layer.fillColor = (index == selectedIndex ? selectedOverlayColor : overlayColor).cgColor
            layer.strokeColor = (index == selectedIndex ? UIColor.systemYellow : UIColor.clear).cgColor
            layer.lineWidth = 2
        }

        guard let selectedIndex, cuts.indices.contains(selectedIndex) else {
            startHandle.isHidden = true
            endHandle.isHidden = true
            return
        }

        let selectedFrame = frame(for: cuts[selectedIndex])
        let hitWidth: CGFloat = 44
        startHandle.frame = CGRect(
            x: selectedFrame.minX - hitWidth / 2,
            y: bounds.midY - 22,
            width: hitWidth,
            height: 44
        )
        endHandle.frame = CGRect(
            x: selectedFrame.maxX - hitWidth / 2,
            y: bounds.midY - 22,
            width: hitWidth,
            height: 44
        )
        startHandle.isHidden = false
        endHandle.isHidden = false
        bringSubviewToFront(startHandle)
        bringSubviewToFront(endHandle)
    }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return true }
        let velocity = pan.velocity(in: self)
        return abs(velocity.x) > abs(velocity.y)
    }

    private func synchronizeLayers() {
        guard cutLayers.count != cuts.count else { return }
        cutLayers.forEach { $0.removeFromSuperlayer() }
        cutLayers = cuts.map { _ in CAShapeLayer() }
        cutLayers.forEach { layer.insertSublayer($0, at: 0) }
    }

    @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
        let point = recognizer.location(in: self)
        if let index = cuts.firstIndex(where: { frame(for: $0).insetBy(dx: -6, dy: -8).contains(point) }) {
            onSelectCut?(index)
        }
    }

    @objc private func handleStartPan(_ recognizer: UIPanGestureRecognizer) {
        handlePan(recognizer, handle: .start)
    }

    @objc private func handleEndPan(_ recognizer: UIPanGestureRecognizer) {
        handlePan(recognizer, handle: .end)
    }

    private func handlePan(_ recognizer: UIPanGestureRecognizer, handle: Handle) {
        guard let selectedIndex, cuts.indices.contains(selectedIndex) else { return }

        switch recognizer.state {
        case .began:
            activeHandle = handle
            onHandleDragStateChanged?(handle, true)
        case .changed:
            guard activeHandle == handle else { return }
            let deltaX = recognizer.translation(in: self).x
            recognizer.setTranslation(.zero, in: self)
            let deltaTime = TimeInterval(deltaX / max(pointsPerSecond, 0.001))
            var cut = cuts[selectedIndex]

            switch handle {
            case .start:
                cut.startTime = min(max(0, cut.startTime + deltaTime), cut.endTime - 0.1)
            case .end:
                cut.endTime = max(min(duration, cut.endTime + deltaTime), cut.startTime + 0.1)
            }

            cuts[selectedIndex] = cut
            onUpdateSelectedCut?(cut, handle)
        case .ended, .cancelled, .failed:
            activeHandle = nil
            onHandleDragStateChanged?(handle, false)
        default:
            break
        }
    }

    private func frame(for cut: VideoCut) -> CGRect {
        let startX = CGFloat(cut.startTime) * pointsPerSecond
        let endX = CGFloat(cut.endTime) * pointsPerSecond
        return CGRect(
            x: startX,
            y: 2,
            width: max(2, endX - startX),
            height: max(1, bounds.height - 4)
        )
    }
}

@MainActor
private final class HandleView: UIView {
    private let visualBar = UIView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = true
        visualBar.backgroundColor = .systemYellow
        visualBar.layer.cornerRadius = 2.5
        visualBar.isUserInteractionEnabled = false
        addSubview(visualBar)
        accessibilityTraits = .adjustable
    }

    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        visualBar.frame = CGRect(x: bounds.midX - 3, y: 4, width: 6, height: bounds.height - 8)
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        bounds.contains(point)
    }
}
#endif
