import Foundation

#if canImport(UIKit) && canImport(AVFoundation)
import UIKit
@preconcurrency import AVFoundation
@preconcurrency import Photos

@MainActor
public final class VideoCutViewController: UIViewController {
    public var onExportCompleted: ((URL) -> Void)?

    private let videoURL: URL
    private let asset: AVURLAsset
    private var cuts: [VideoCut]

    private enum InteractionState {
        case idle
        case playing
        case userScrubbing
        case previewingFinal
        case exporting
    }

    private let player = AVPlayer()
    private let playerLayer = AVPlayerLayer()
    private var timeObserver: Any?
    private var interactionState: InteractionState = .idle
    private var previewCuts: [VideoCut] = []
    private var previewCutIndex = 0
    private var isAdvancingFinalPreview = false
    private var pendingScrubTime: TimeInterval?
    private var scrubSeekInFlight = false
    private var scrubSeekGeneration = 0

    private let exporter = VideoCutExporter()
    private let videoContainer = UIView()
    private let playPauseButton = UIButton(type: .system)
    private let timeLabel = UILabel()
    private let timelineContainer = UIView()
    private var timelineView: VideoTimelineView?
    private let addCutButton = UIButton(type: .system)
    private let previewButton = UIButton(type: .system)
    private let zoomOutButton = UIButton(type: .system)
    private let zoomInButton = UIButton(type: .system)
    private let cutsTableView = UITableView(frame: .zero, style: .plain)
    private let progressContainer = UIStackView()
    private let progressView = UIProgressView(progressViewStyle: .default)
    private let cancelExportButton = UIButton(type: .system)

    public init(videoURL: URL, cuts: [VideoCut]) {
        self.videoURL = videoURL
        self.asset = AVURLAsset(url: videoURL)
        self.cuts = cuts
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    public override func viewDidLoad() {
        super.viewDidLoad()
        normalizeCuts()
        setupUI()
        configurePlayer()
        configureTimeline()
    }

    public override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        player.pause()
        removeTimeObserver()
        timelineView?.cancelThumbnailLoading()
        if interactionState == .exporting {
            exporter.cancel()
        }
    }

    public override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        installTimeObserverIfNeeded()
        timelineView?.coordinateInteractivePopGesture(
            navigationController?.interactivePopGestureRecognizer
        )
        updateZoomButtons()
    }

    public override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        playerLayer.frame = videoContainer.bounds
    }

    private func setupUI() {
        view.backgroundColor = UIColor(red: 0.025, green: 0.045, blue: 0.055, alpha: 1)
        navigationItem.title = "Cut Highlights"
        navigationItem.leftBarButtonItem = UIBarButtonItem(title: "Cancel", style: .plain, target: self, action: #selector(cancelTapped))

        let doneButton = UIButton(type: .system)
        doneButton.configuration = .filled()
        doneButton.configuration?.title = "Done (\(cuts.count))"
        doneButton.configuration?.baseBackgroundColor = .systemYellow
        doneButton.configuration?.baseForegroundColor = .black
        doneButton.configuration?.cornerStyle = .capsule
        doneButton.titleLabel?.font = .preferredFont(forTextStyle: .headline)
        doneButton.addTarget(self, action: #selector(doneTapped), for: .touchUpInside)
        navigationItem.rightBarButtonItem = UIBarButtonItem(customView: doneButton)

        videoContainer.backgroundColor = .black
        videoContainer.clipsToBounds = true
        videoContainer.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(videoContainer)
        playerLayer.videoGravity = .resizeAspect
        videoContainer.layer.addSublayer(playerLayer)

        configurePlayerControls()
        configureActionButtons()

        timelineContainer.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(timelineContainer)

        cutsTableView.dataSource = self
        cutsTableView.delegate = self
        cutsTableView.backgroundColor = .clear
        cutsTableView.separatorStyle = .none
        cutsTableView.rowHeight = 88
        cutsTableView.contentInset = UIEdgeInsets(top: 4, left: 0, bottom: 12, right: 0)
        cutsTableView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(cutsTableView)

        progressView.progressTintColor = .systemYellow
        progressView.trackTintColor = UIColor.white.withAlphaComponent(0.15)
        cancelExportButton.setTitle("Cancel Export", for: .normal)
        cancelExportButton.tintColor = .systemYellow
        cancelExportButton.addTarget(self, action: #selector(cancelExportTapped), for: .touchUpInside)
        progressContainer.axis = .vertical
        progressContainer.spacing = 6
        progressContainer.addArrangedSubview(progressView)
        progressContainer.addArrangedSubview(cancelExportButton)
        progressContainer.isHidden = true
        progressContainer.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(progressContainer)

        let safe = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            videoContainer.topAnchor.constraint(equalTo: safe.topAnchor),
            videoContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            videoContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            videoContainer.heightAnchor.constraint(equalTo: videoContainer.widthAnchor, multiplier: 9.0 / 16.0),

            timelineContainer.topAnchor.constraint(equalTo: videoContainer.bottomAnchor, constant: 54),
            timelineContainer.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 16),
            timelineContainer.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -16),
            timelineContainer.heightAnchor.constraint(equalToConstant: 72),

            addCutButton.topAnchor.constraint(equalTo: timelineContainer.bottomAnchor, constant: 14),
            addCutButton.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 24),
            addCutButton.heightAnchor.constraint(equalToConstant: 48),
            addCutButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 120),

            zoomOutButton.centerYAnchor.constraint(equalTo: addCutButton.centerYAnchor),
            zoomOutButton.leadingAnchor.constraint(equalTo: addCutButton.trailingAnchor, constant: 8),
            zoomOutButton.widthAnchor.constraint(equalToConstant: 44),
            zoomOutButton.heightAnchor.constraint(equalToConstant: 44),

            zoomInButton.centerYAnchor.constraint(equalTo: addCutButton.centerYAnchor),
            zoomInButton.leadingAnchor.constraint(equalTo: zoomOutButton.trailingAnchor, constant: 8),
            zoomInButton.widthAnchor.constraint(equalToConstant: 44),
            zoomInButton.heightAnchor.constraint(equalToConstant: 44),

            previewButton.centerYAnchor.constraint(equalTo: addCutButton.centerYAnchor),
            previewButton.leadingAnchor.constraint(equalTo: zoomInButton.trailingAnchor, constant: 8),
            previewButton.trailingAnchor.constraint(lessThanOrEqualTo: safe.trailingAnchor, constant: -20),
            previewButton.heightAnchor.constraint(equalToConstant: 44),
            previewButton.widthAnchor.constraint(equalToConstant: 44),

            cutsTableView.topAnchor.constraint(equalTo: addCutButton.bottomAnchor, constant: 10),
            cutsTableView.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 16),
            cutsTableView.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -16),
            cutsTableView.bottomAnchor.constraint(equalTo: safe.bottomAnchor),

            progressContainer.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 24),
            progressContainer.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -24),
            progressContainer.bottomAnchor.constraint(equalTo: safe.bottomAnchor, constant: -12)
        ])
    }

    private func configurePlayerControls() {
        var configuration = UIButton.Configuration.plain()
        configuration.image = UIImage(
            systemName: "play.fill",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold)
        )
        configuration.baseForegroundColor = .white
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 10, bottom: 10, trailing: 10)
        configuration.background.backgroundColor = UIColor.black.withAlphaComponent(0.4)
        configuration.background.cornerRadius = 22
        playPauseButton.configuration = configuration
        playPauseButton.addTarget(self, action: #selector(playPauseTapped), for: .touchUpInside)
        playPauseButton.accessibilityLabel = "Play or pause video"
        playPauseButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(playPauseButton)

        timeLabel.textColor = .white
        timeLabel.font = UIFontMetrics(forTextStyle: .subheadline).scaledFont(
            for: .monospacedDigitSystemFont(ofSize: 15, weight: .semibold)
        )
        timeLabel.adjustsFontForContentSizeCategory = true
        timeLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(timeLabel)

        NSLayoutConstraint.activate([
            playPauseButton.leadingAnchor.constraint(equalTo: videoContainer.leadingAnchor, constant: 20),
            playPauseButton.bottomAnchor.constraint(equalTo: videoContainer.bottomAnchor, constant: -12),
            playPauseButton.widthAnchor.constraint(equalToConstant: 44),
            playPauseButton.heightAnchor.constraint(equalToConstant: 44),
            timeLabel.leadingAnchor.constraint(equalTo: playPauseButton.trailingAnchor, constant: 12),
            timeLabel.centerYAnchor.constraint(equalTo: playPauseButton.centerYAnchor)
        ])
    }

    private func configureActionButtons() {
        addCutButton.configuration = .bordered()
        addCutButton.configuration?.title = "Add Cut"
        addCutButton.configuration?.image = UIImage(systemName: "plus.circle")
        addCutButton.configuration?.imagePadding = 10
        addCutButton.configuration?.baseForegroundColor = .white
        addCutButton.configuration?.cornerStyle = .capsule
        addCutButton.layer.borderColor = UIColor.white.withAlphaComponent(0.45).cgColor
        addCutButton.layer.borderWidth = 1
        addCutButton.layer.cornerRadius = 24
        addCutButton.addTarget(self, action: #selector(addCutTapped), for: .touchUpInside)
        addCutButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(addCutButton)

        previewButton.configuration = .bordered()
        previewButton.configuration?.image = UIImage(systemName: "play.rectangle")
        previewButton.configuration?.baseForegroundColor = .white
        previewButton.configuration?.cornerStyle = .capsule
        previewButton.layer.borderColor = UIColor.white.withAlphaComponent(0.2).cgColor
        previewButton.layer.borderWidth = 1
        previewButton.layer.cornerRadius = 24
        previewButton.addTarget(self, action: #selector(previewFinalTapped), for: .touchUpInside)
        previewButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(previewButton)

        configureZoomButton(zoomOutButton, imageName: "minus.magnifyingglass", action: #selector(zoomOutTapped))
        configureZoomButton(zoomInButton, imageName: "plus.magnifyingglass", action: #selector(zoomInTapped))
    }

    private func configureZoomButton(_ button: UIButton, imageName: String, action: Selector) {
        var configuration = UIButton.Configuration.bordered()
        configuration.image = UIImage(
            systemName: imageName,
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .medium)
        )
        configuration.baseForegroundColor = .white
        configuration.cornerStyle = .capsule
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 10, bottom: 10, trailing: 10)
        button.configuration = configuration
        button.addTarget(self, action: action, for: .touchUpInside)
        button.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(button)
    }

    private func configurePlayer() {
        player.replaceCurrentItem(with: AVPlayerItem(asset: asset))
        playerLayer.player = player
        installTimeObserverIfNeeded()
        refreshPlaybackUI()
    }

    private func installTimeObserverIfNeeded() {
        guard timeObserver == nil else { return }
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 1.0 / 30.0, preferredTimescale: 600),
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshPlaybackUI()
            }
        }
    }

    private func removeTimeObserver() {
        guard let timeObserver else { return }
        player.removeTimeObserver(timeObserver)
        self.timeObserver = nil
    }

    private func configureTimeline() {
        let timeline = VideoTimelineView(asset: asset)
        timeline.translatesAutoresizingMaskIntoConstraints = false
        timeline.cuts = cuts
        timeline.selectedCutIndex = nil
        timeline.onSeekRequested = { [weak self] time in
            self?.requestScrubSeek(to: time)
        }
        timeline.onFinalSeekRequested = { [weak self] time in
            self?.finishScrubSeek(at: time)
        }
        timeline.onCurrentTimeChanged = { [weak self] time in
            self?.updateTimeLabel(for: time)
        }
        timeline.onScrubbingChanged = { [weak self] isScrubbing in
            guard let self else { return }
            if isScrubbing {
                self.player.pause()
                self.interactionState = .userScrubbing
            } else {
                self.interactionState = .idle
            }
            self.updatePlayButton()
        }
        timeline.onZoomChanged = { [weak self] _ in
            self?.updateZoomButtons()
        }
        timeline.onSelectedCutChanged = { [weak self] index in self?.showEditor(for: index) }
        timelineContainer.addSubview(timeline)
        NSLayoutConstraint.activate([
            timeline.topAnchor.constraint(equalTo: timelineContainer.topAnchor),
            timeline.leadingAnchor.constraint(equalTo: timelineContainer.leadingAnchor),
            timeline.trailingAnchor.constraint(equalTo: timelineContainer.trailingAnchor),
            timeline.bottomAnchor.constraint(equalTo: timelineContainer.bottomAnchor)
        ])
        timelineView = timeline
    }

    private func normalizeCuts() {
        cuts = VideoCutValidator.clampedCuts(cuts, duration: CMTimeGetSeconds(asset.duration))
    }

    private func refreshData() {
        normalizeCuts()
        timelineView?.cuts = cuts
        cutsTableView.reloadData()
        if let button = navigationItem.rightBarButtonItem?.customView as? UIButton {
            button.configuration?.title = "Done (\(cuts.count))"
        }
    }

    private func showEditor(for index: Int) {
        guard cuts.indices.contains(index) else { return }
        timelineView?.selectedCutIndex = index
        timelineView?.scrollToCut(index: index, animated: true)
        player.pause()
        updatePlayButton()

        let editor = CutDetailViewController(
            asset: asset,
            cut: cuts[index],
            cutIndex: index,
            totalCount: cuts.count
        )
        editor.onCutChanged = { [weak self] updatedCut in
            guard let self, self.cuts.indices.contains(index) else { return }
            self.cuts[index] = updatedCut
            self.timelineView?.updateCut(at: index, with: updatedCut)
            self.cutsTableView.reloadRows(
                at: [IndexPath(row: index, section: 0)],
                with: .none
            )
        }
        editor.onDelete = { [weak self] in
            guard let self, self.cuts.indices.contains(index) else { return }
            self.cuts.remove(at: index)
            self.refreshData()
        }

        if let navigationController {
            navigationController.pushViewController(editor, animated: true)
        } else {
            let navigationController = UINavigationController(rootViewController: editor)
            navigationController.modalPresentationStyle = .fullScreen
            present(navigationController, animated: true)
        }
    }

    @objc private func playPauseTapped() {
        previewCuts = []
        isAdvancingFinalPreview = false
        if player.timeControlStatus == .playing {
            player.pause()
            interactionState = .idle
        } else {
            player.play()
            interactionState = .playing
        }
        updatePlayButton()
    }

    @objc private func addCutTapped() {
        let duration = CMTimeGetSeconds(asset.duration)
        guard duration.isFinite, duration > 0 else { return }

        let defaultDuration = min(5, duration)
        let center = timelineView?.currentTime ?? currentTime
        var start = center - defaultDuration / 2
        var end = center + defaultDuration / 2
        if start < 0 {
            end = min(duration, end - start)
            start = 0
        }
        if end > duration {
            start = max(0, start - (end - duration))
            end = duration
        }
        guard end > start else { return }

        cuts.append(VideoCut(startTime: start, endTime: end))
        let newIndex = cuts.count - 1
        refreshData()
        timelineView?.selectedCutIndex = newIndex
        timelineView?.scrollToCut(index: newIndex, animated: true)
        showEditor(for: newIndex)
    }

    @objc private func previewFinalTapped() {
        let duration = CMTimeGetSeconds(asset.duration)
        previewCuts = VideoCutValidator.normalizedCuts(cuts, duration: duration)
        guard let firstCut = previewCuts.first else {
            presentAlert(title: "Nothing to Preview", message: "Add at least one valid cut first.")
            return
        }

        player.pause()
        previewCutIndex = 0
        isAdvancingFinalPreview = true
        interactionState = .previewingFinal
        seek(to: firstCut.startTime, precise: true) { [weak self] finished in
            guard let self, finished, self.interactionState == .previewingFinal else { return }
            self.isAdvancingFinalPreview = false
            self.timelineView?.setCurrentTime(firstCut.startTime)
            self.player.play()
            self.updatePlayButton()
        }
    }

    @objc private func zoomOutTapped() {
        timelineView?.zoomOut()
        updateZoomButtons()
    }

    @objc private func zoomInTapped() {
        timelineView?.zoomIn()
        updateZoomButtons()
    }

    private func updateZoomButtons() {
        zoomOutButton.isEnabled = timelineView?.canZoomOut ?? false
        zoomInButton.isEnabled = timelineView?.canZoomIn ?? false
    }

    @objc private func cancelTapped() {
        dismiss(animated: true)
    }

    @objc private func doneTapped() {
        normalizeCuts()
        let outputURL: URL
        do {
            outputURL = try VideoCutFileManager.makeOutputURL()
            VideoCutFileManager.remove(outputURL)
        } catch {
            presentAlert(title: "Export Error", message: error.localizedDescription)
            return
        }

        interactionState = .exporting
        player.pause()
        progressContainer.isHidden = false
        cutsTableView.isHidden = true
        navigationItem.rightBarButtonItem?.isEnabled = false
        exporter.export(
            sourceURL: videoURL,
            cuts: cuts,
            outputURL: outputURL,
            progress: { [weak self] value in
                Task { @MainActor in self?.progressView.progress = value }
            },
            completion: { [weak self] result in
                Task { @MainActor in
                    guard let self else { return }
                    self.interactionState = .idle
                    self.progressContainer.isHidden = true
                    self.cutsTableView.isHidden = false
                    self.navigationItem.rightBarButtonItem?.isEnabled = true
                    switch result {
                    case .success(let url):
                        do {
                            try await self.saveExportToPhotos(url)
                            self.onExportCompleted?(url)
                            self.presentAlert(
                                title: "Saved",
                                message: "The highlight video was saved to your Photos Library."
                            ) {
                                self.dismiss(animated: true)
                            }
                        } catch {
                            self.presentAlert(title: "Save Error", message: error.localizedDescription)
                        }
                    case .failure(let error):
                        self.presentAlert(title: "Export Error", message: error.localizedDescription)
                    }
                }
            }
        )
    }

    @objc private func cancelExportTapped() {
        exporter.cancel()
        interactionState = .idle
        progressContainer.isHidden = true
        cutsTableView.isHidden = false
        navigationItem.rightBarButtonItem?.isEnabled = true
    }

    private func seek(
        to time: TimeInterval,
        precise: Bool = true,
        completion: (@MainActor @Sendable (Bool) -> Void)? = nil
    ) {
        player.currentItem?.cancelPendingSeeks()
        let tolerance = precise
            ? CMTime.zero
            : CMTime(seconds: 1.0 / 15.0, preferredTimescale: 600)
        player.seek(
            to: CMTime(seconds: time, preferredTimescale: 600),
            toleranceBefore: tolerance,
            toleranceAfter: tolerance,
            completionHandler: { finished in
                Task { @MainActor in completion?(finished) }
            }
        )
    }

    private func requestScrubSeek(to time: TimeInterval) {
        pendingScrubTime = time
        guard !scrubSeekInFlight else { return }
        performNextScrubSeek()
    }

    private func performNextScrubSeek() {
        guard let time = pendingScrubTime else {
            scrubSeekInFlight = false
            return
        }

        pendingScrubTime = nil
        scrubSeekInFlight = true
        let generation = scrubSeekGeneration
        let tolerance = CMTime(seconds: 1.0 / 12.0, preferredTimescale: 600)
        player.seek(
            to: CMTime(seconds: time, preferredTimescale: 600),
            toleranceBefore: tolerance,
            toleranceAfter: tolerance
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, generation == self.scrubSeekGeneration else { return }
                self.scrubSeekInFlight = false
                self.performNextScrubSeek()
            }
        }
    }

    private func finishScrubSeek(at time: TimeInterval) {
        scrubSeekGeneration += 1
        pendingScrubTime = nil
        scrubSeekInFlight = false
        seek(to: time, precise: true)
    }

    private func updateTimeLabel(for time: TimeInterval) {
        let duration = CMTimeGetSeconds(asset.duration)
        timeLabel.text = "\(VideoCutFormatting.shortTime(time)) / \(VideoCutFormatting.shortTime(duration))"
    }

    private var currentTime: TimeInterval {
        let seconds = CMTimeGetSeconds(player.currentTime())
        return seconds.isFinite ? seconds : 0
    }

    private func refreshPlaybackUI() {
        let duration = CMTimeGetSeconds(asset.duration)
        let playbackTime = currentTime
        timeLabel.text = "\(VideoCutFormatting.shortTime(playbackTime)) / \(VideoCutFormatting.shortTime(duration))"

        if interactionState != .userScrubbing {
            timelineView?.updatePlayhead(currentTime: playbackTime)
        }
        updatePlayButton()

        guard interactionState == .previewingFinal,
              previewCuts.indices.contains(previewCutIndex),
              !isAdvancingFinalPreview else { return }

        let cut = previewCuts[previewCutIndex]
        guard playbackTime >= cut.endTime - 0.02 else { return }

        player.pause()
        let nextIndex = previewCutIndex + 1
        guard previewCuts.indices.contains(nextIndex) else {
            interactionState = .idle
            previewCuts = []
            timelineView?.setCurrentTime(cut.endTime)
            updatePlayButton()
            return
        }

        previewCutIndex = nextIndex
        let nextCut = previewCuts[nextIndex]
        isAdvancingFinalPreview = true
        seek(to: nextCut.startTime, precise: true) { [weak self] finished in
            guard let self, finished, self.interactionState == .previewingFinal else { return }
            self.isAdvancingFinalPreview = false
            self.timelineView?.setCurrentTime(nextCut.startTime)
            self.player.play()
            self.updatePlayButton()
        }
    }

    private func updatePlayButton() {
        let imageName = player.timeControlStatus == .playing ? "pause.fill" : "play.fill"
        playPauseButton.configuration?.image = UIImage(
            systemName: imageName,
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold)
        )
    }

    private func saveExportToPhotos(_ url: URL) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        switch status {
        case .authorized, .limited:
            break
        case .denied:
            throw PhotoSaveError.denied
        case .restricted:
            throw PhotoSaveError.restricted
        case .notDetermined:
            throw PhotoSaveError.notDetermined
        @unknown default:
            throw PhotoSaveError.unavailable
        }

        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            request.addResource(with: .video, fileURL: url, options: nil)
        }
    }

    private func presentAlert(
        title: String,
        message: String,
        completion: (() -> Void)? = nil
    ) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completion?() })
        present(alert, animated: true)
    }
}

extension VideoCutViewController: UITableViewDataSource, UITableViewDelegate {
    public func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        cuts.count
    }

    public func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let identifier = "CutCell"
        let cell = tableView.dequeueReusableCell(withIdentifier: identifier)
            ?? UITableViewCell(style: .subtitle, reuseIdentifier: identifier)
        let cut = cuts[indexPath.row]

        var configuration = cell.defaultContentConfiguration()
        configuration.text = "\(indexPath.row + 1).  \(VideoCutFormatting.shortTime(cut.startTime)) - \(VideoCutFormatting.shortTime(cut.endTime))"
        configuration.secondaryText = String(format: "%.1fs", max(0, cut.endTime - cut.startTime))
        configuration.textProperties.color = .white
        configuration.textProperties.font = .preferredFont(forTextStyle: .headline)
        configuration.secondaryTextProperties.color = .lightGray
        configuration.image = UIImage(systemName: "film")
        configuration.imageProperties.tintColor = .systemYellow
        configuration.imageProperties.maximumSize = CGSize(width: 58, height: 58)
        cell.contentConfiguration = configuration
        cell.accessoryType = .disclosureIndicator
        cell.tintColor = .systemYellow
        cell.backgroundColor = UIColor.white.withAlphaComponent(0.055)
        cell.layer.cornerRadius = 14
        cell.layer.borderWidth = 1
        cell.layer.borderColor = UIColor.white.withAlphaComponent(0.08).cgColor
        cell.clipsToBounds = true
        return cell
    }

    public func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        showEditor(for: indexPath.row)
    }
}

private enum PhotoSaveError: LocalizedError {
    case denied
    case restricted
    case notDetermined
    case unavailable

    var errorDescription: String? {
        switch self {
        case .denied:
            return "Photos access was denied. Enable Add Photos Only access in Settings and try again."
        case .restricted:
            return "Photos access is restricted on this device."
        case .notDetermined:
            return "Photos permission wasn’t resolved. Please try again."
        case .unavailable:
            return "The Photos Library isn’t available."
        }
    }
}

@MainActor
private final class CutDetailViewController: UIViewController {
    var onCutChanged: ((VideoCut) -> Void)?
    var onDelete: (() -> Void)?

    private let asset: AVAsset
    private var cut: VideoCut
    private let cutIndex: Int
    private let totalCount: Int

    private enum InteractionState {
        case idle
        case playing
        case userScrubbing
        case draggingStartHandle
        case draggingEndHandle
        case previewingSegment
    }

    private let player = AVPlayer()
    private let playerLayer = AVPlayerLayer()
    private var timeObserver: Any?
    private var interactionState: InteractionState = .idle
    private var pendingScrubTime: TimeInterval?
    private var scrubSeekInFlight = false
    private var scrubSeekGeneration = 0
    private let videoContainer = UIView()
    private let playButton = UIButton(type: .system)
    private let timeLabel = UILabel()
    private let timelineContainer = UIView()
    private var timelineView: VideoTimelineView?
    private let startField = UITextField()
    private let endField = UITextField()
    private let durationLabel = UILabel()

    init(asset: AVAsset, cut: VideoCut, cutIndex: Int, totalCount: Int) {
        self.asset = asset
        self.cut = cut
        self.cutIndex = cutIndex
        self.totalCount = totalCount
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        configurePlayer()
        configureTimeline()
        refreshFields()
        seek(to: cut.startTime)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        installTimeObserverIfNeeded()
        timelineView?.coordinateInteractivePopGesture(
            navigationController?.interactivePopGestureRecognizer
        )
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        player.pause()
        removeTimeObserver()
        timelineView?.cancelThumbnailLoading()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        playerLayer.frame = videoContainer.bounds
    }

    private func setupUI() {
        view.backgroundColor = UIColor(red: 0.025, green: 0.045, blue: 0.055, alpha: 1)
        title = "Cut \(cutIndex + 1) of \(totalCount)"
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: "Delete",
            style: .plain,
            target: self,
            action: #selector(deleteTapped)
        )
        navigationItem.rightBarButtonItem?.tintColor = .systemRed

        let scrollView = UIScrollView()
        let contentView = UIView()
        scrollView.alwaysBounceVertical = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        contentView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)
        scrollView.addSubview(contentView)

        videoContainer.backgroundColor = .black
        videoContainer.clipsToBounds = true
        videoContainer.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(videoContainer)
        playerLayer.videoGravity = .resizeAspect
        videoContainer.layer.addSublayer(playerLayer)

        var playConfiguration = UIButton.Configuration.plain()
        playConfiguration.image = UIImage(
            systemName: "play.fill",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold)
        )
        playConfiguration.baseForegroundColor = .white
        playConfiguration.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 10, bottom: 10, trailing: 10)
        playConfiguration.background.backgroundColor = UIColor.black.withAlphaComponent(0.4)
        playConfiguration.background.cornerRadius = 22
        playButton.configuration = playConfiguration
        playButton.addTarget(self, action: #selector(playTapped), for: .touchUpInside)
        playButton.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(playButton)

        timeLabel.textColor = .white
        timeLabel.font = UIFontMetrics(forTextStyle: .subheadline).scaledFont(
            for: .monospacedDigitSystemFont(ofSize: 15, weight: .semibold)
        )
        timeLabel.adjustsFontForContentSizeCategory = true
        timeLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(timeLabel)

        timelineContainer.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(timelineContainer)

        let card = makeTimeCard()
        card.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(card)

        let previewButton = UIButton(type: .system)
        previewButton.configuration = .filled()
        previewButton.configuration?.title = "Preview Segment"
        previewButton.configuration?.image = UIImage(systemName: "play.fill")
        previewButton.configuration?.imagePadding = 8
        previewButton.configuration?.baseBackgroundColor = .systemYellow
        previewButton.configuration?.baseForegroundColor = .black
        previewButton.configuration?.cornerStyle = .capsule
        previewButton.addTarget(self, action: #selector(previewTapped), for: .touchUpInside)
        previewButton.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(previewButton)

        let safe = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: safe.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            contentView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            contentView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            contentView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            contentView.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),

            videoContainer.topAnchor.constraint(equalTo: contentView.topAnchor),
            videoContainer.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            videoContainer.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            videoContainer.heightAnchor.constraint(equalTo: videoContainer.widthAnchor, multiplier: 9.0 / 16.0),

            playButton.leadingAnchor.constraint(equalTo: videoContainer.leadingAnchor, constant: 20),
            playButton.bottomAnchor.constraint(equalTo: videoContainer.bottomAnchor, constant: -12),
            playButton.widthAnchor.constraint(equalToConstant: 44),
            playButton.heightAnchor.constraint(equalToConstant: 44),
            timeLabel.leadingAnchor.constraint(equalTo: playButton.trailingAnchor, constant: 12),
            timeLabel.centerYAnchor.constraint(equalTo: playButton.centerYAnchor),

            timelineContainer.topAnchor.constraint(equalTo: videoContainer.bottomAnchor, constant: 64),
            timelineContainer.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            timelineContainer.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            timelineContainer.heightAnchor.constraint(equalToConstant: 86),

            card.topAnchor.constraint(equalTo: timelineContainer.bottomAnchor, constant: 24),
            card.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            card.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),

            previewButton.topAnchor.constraint(equalTo: card.bottomAnchor, constant: 18),
            previewButton.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 40),
            previewButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -40),
            previewButton.heightAnchor.constraint(equalToConstant: 50),
            previewButton.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -28)
        ])
    }

    private func makeTimeCard() -> UIView {
        let card = UIView()
        card.backgroundColor = UIColor.white.withAlphaComponent(0.055)
        card.layer.cornerRadius = 16
        card.layer.borderWidth = 1
        card.layer.borderColor = UIColor.white.withAlphaComponent(0.08).cgColor

        let heading = UILabel()
        heading.text = "Selected Segment"
        heading.textColor = .white
        heading.font = .preferredFont(forTextStyle: .headline)

        durationLabel.textColor = .white
        durationLabel.font = .monospacedDigitSystemFont(ofSize: 16, weight: .medium)
        durationLabel.textAlignment = .right

        configureTimeField(startField, placeholder: "Start Time")
        configureTimeField(endField, placeholder: "End Time")

        let titleRow = UIStackView(arrangedSubviews: [heading, durationLabel])
        titleRow.distribution = .fillEqually
        let fields = UIStackView(arrangedSubviews: [
            labeledField(title: "Start Time", field: startField),
            labeledField(title: "End Time", field: endField)
        ])
        fields.axis = .horizontal
        fields.spacing = 14
        fields.distribution = .fillEqually

        let stack = UIStackView(arrangedSubviews: [titleRow, fields])
        stack.axis = .vertical
        stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 18),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -18),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -18)
        ])
        return card
    }

    private func configureTimeField(_ field: UITextField, placeholder: String) {
        field.placeholder = placeholder
        field.keyboardType = .numbersAndPunctuation
        field.textColor = .white
        field.font = UIFontMetrics(forTextStyle: .title2).scaledFont(
            for: .monospacedDigitSystemFont(ofSize: 22, weight: .semibold)
        )
        field.adjustsFontForContentSizeCategory = true
        field.textAlignment = .center
        field.backgroundColor = UIColor.white.withAlphaComponent(0.08)
        field.layer.cornerRadius = 12
        field.layer.borderWidth = 1
        field.layer.borderColor = UIColor.white.withAlphaComponent(0.12).cgColor
        field.addTarget(self, action: #selector(timeChanged(_:)), for: .editingDidEnd)
        field.heightAnchor.constraint(equalToConstant: 60).isActive = true
    }

    private func labeledField(title: String, field: UITextField) -> UIView {
        let label = UILabel()
        label.text = title
        label.textColor = .lightGray
        label.font = .preferredFont(forTextStyle: .subheadline)
        let stack = UIStackView(arrangedSubviews: [label, field])
        stack.axis = .vertical
        stack.spacing = 8
        return stack
    }

    private func configurePlayer() {
        player.replaceCurrentItem(with: AVPlayerItem(asset: asset))
        playerLayer.player = player
        installTimeObserverIfNeeded()
    }

    private func installTimeObserverIfNeeded() {
        guard timeObserver == nil else { return }
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 1.0 / 30.0, preferredTimescale: 600),
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshPlaybackUI()
            }
        }
    }

    private func removeTimeObserver() {
        guard let timeObserver else { return }
        player.removeTimeObserver(timeObserver)
        self.timeObserver = nil
    }

    private func configureTimeline() {
        let timeline = VideoTimelineView(asset: asset)
        timeline.translatesAutoresizingMaskIntoConstraints = false
        timeline.cuts = [cut]
        timeline.selectedCutIndex = 0
        timeline.onSeekRequested = { [weak self] time in
            self?.requestScrubSeek(to: time)
        }
        timeline.onFinalSeekRequested = { [weak self] time in
            self?.finishScrubSeek(at: time)
        }
        timeline.onCurrentTimeChanged = { [weak self] time in
            guard let self else { return }
            self.timeLabel.text = "\(VideoCutFormatting.shortTime(time)) / \(VideoCutFormatting.shortTime(CMTimeGetSeconds(self.asset.duration)))"
        }
        timeline.onInteractionChanged = { [weak self] interaction in
            guard let self else { return }
            switch interaction {
            case .idle:
                self.interactionState = .idle
            case .userScrubbing:
                self.player.pause()
                self.interactionState = .userScrubbing
            case .draggingStartHandle:
                self.player.pause()
                self.interactionState = .draggingStartHandle
            case .draggingEndHandle:
                self.player.pause()
                self.interactionState = .draggingEndHandle
            }
            self.updatePlayButton()
        }
        timeline.onSelectedCutUpdated = { [weak self] updatedCut in
            self?.apply(updatedCut)
        }
        timelineContainer.addSubview(timeline)
        NSLayoutConstraint.activate([
            timeline.topAnchor.constraint(equalTo: timelineContainer.topAnchor),
            timeline.leadingAnchor.constraint(equalTo: timelineContainer.leadingAnchor),
            timeline.trailingAnchor.constraint(equalTo: timelineContainer.trailingAnchor),
            timeline.bottomAnchor.constraint(equalTo: timelineContainer.bottomAnchor)
        ])
        timelineView = timeline
        timeline.setCurrentTime(cut.startTime)
    }

    private func apply(_ updatedCut: VideoCut) {
        cut = updatedCut
        timelineView?.cuts = [cut]
        timelineView?.selectedCutIndex = 0
        refreshFields()
        onCutChanged?(cut)
    }

    private func refreshFields() {
        startField.text = VideoCutFormatting.shortTime(cut.startTime)
        endField.text = VideoCutFormatting.shortTime(cut.endTime)
        durationLabel.text = String(format: "%.1fs", cut.endTime - cut.startTime)
    }

    @objc private func timeChanged(_ sender: UITextField) {
        guard let value = parseTime(sender.text ?? "") else {
            refreshFields()
            return
        }
        let duration = CMTimeGetSeconds(asset.duration)
        var updatedCut = cut
        if sender === startField {
            updatedCut.startTime = max(0, min(updatedCut.endTime - 0.1, value))
        } else {
            updatedCut.endTime = min(duration, max(updatedCut.startTime + 0.1, value))
        }
        apply(updatedCut)
        seek(to: sender === startField ? updatedCut.startTime : updatedCut.endTime)
    }

    @objc private func playTapped() {
        if player.timeControlStatus == .playing {
            player.pause()
            interactionState = .idle
        } else {
            player.play()
            interactionState = .playing
        }
        updatePlayButton()
    }

    @objc private func previewTapped() {
        interactionState = .previewingSegment
        seek(to: cut.startTime, precise: true)
        timelineView?.setCurrentTime(cut.startTime)
        player.play()
        updatePlayButton()
    }

    @objc private func deleteTapped() {
        onDelete?()
        navigationController?.popViewController(animated: true)
    }

    private func refreshPlaybackUI() {
        let current = CMTimeGetSeconds(player.currentTime())
        let safeCurrent = current.isFinite ? current : 0
        timeLabel.text = "\(VideoCutFormatting.shortTime(safeCurrent)) / \(VideoCutFormatting.shortTime(CMTimeGetSeconds(asset.duration)))"
        if interactionState != .userScrubbing,
           interactionState != .draggingStartHandle,
           interactionState != .draggingEndHandle {
            timelineView?.updatePlayhead(currentTime: safeCurrent)
        }
        if interactionState == .previewingSegment, safeCurrent >= cut.endTime - 0.02 {
            player.pause()
            interactionState = .idle
            seek(to: cut.endTime, precise: true)
            timelineView?.setCurrentTime(cut.endTime)
        }
        updatePlayButton()
    }

    private func updatePlayButton() {
        playButton.configuration?.image = UIImage(
            systemName: player.timeControlStatus == .playing ? "pause.fill" : "play.fill",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold)
        )
    }

    private func seek(to time: TimeInterval, precise: Bool = true) {
        player.currentItem?.cancelPendingSeeks()
        let tolerance = precise
            ? CMTime.zero
            : CMTime(seconds: 1.0 / 15.0, preferredTimescale: 600)
        player.seek(
            to: CMTime(seconds: time, preferredTimescale: 600),
            toleranceBefore: tolerance,
            toleranceAfter: tolerance
        )
    }

    private func requestScrubSeek(to time: TimeInterval) {
        pendingScrubTime = time
        guard !scrubSeekInFlight else { return }
        performNextScrubSeek()
    }

    private func performNextScrubSeek() {
        guard let time = pendingScrubTime else {
            scrubSeekInFlight = false
            return
        }

        pendingScrubTime = nil
        scrubSeekInFlight = true
        let generation = scrubSeekGeneration
        let tolerance = CMTime(seconds: 1.0 / 12.0, preferredTimescale: 600)
        player.seek(
            to: CMTime(seconds: time, preferredTimescale: 600),
            toleranceBefore: tolerance,
            toleranceAfter: tolerance
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, generation == self.scrubSeekGeneration else { return }
                self.scrubSeekInFlight = false
                self.performNextScrubSeek()
            }
        }
    }

    private func finishScrubSeek(at time: TimeInterval) {
        scrubSeekGeneration += 1
        pendingScrubTime = nil
        scrubSeekInFlight = false
        seek(to: time, precise: true)
    }

    private func parseTime(_ text: String) -> TimeInterval? {
        let parts = text.split(separator: ":")
        guard parts.count == 2,
              let minutes = Double(parts[0]),
              let seconds = Double(parts[1]) else {
            return Double(text)
        }
        return minutes * 60 + seconds
    }
}
#endif
