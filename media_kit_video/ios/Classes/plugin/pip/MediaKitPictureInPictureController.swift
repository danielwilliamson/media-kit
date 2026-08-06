#if canImport(Flutter)
  import AVFoundation
  import AVKit
  import CoreMedia
  import Flutter
  import UIKit

  /// Bridges `AVPictureInPictureController` with a `media_kit_video`
  /// `VideoOutput` frame source. Requires iOS 15+ to compile-guard access to
  /// `AVSampleBufferDisplayLayer`-based PiP APIs.
  @available(iOS 15.0, *)
  final class MediaKitPictureInPictureController: NSObject {
    typealias EventCallback = ([String: Any]) -> Void

    private let hostView: UIView
    private let outputManager: VideoOutputManager
    private let eventCallback: EventCallback
    private var displayLayer: AVSampleBufferDisplayLayer
    private var pipController: AVPictureInPictureController?
    // Cached so we can rebuild the AVPictureInPictureController
    // after each session ends (the display layer goes stale and the next auto-enter
    // renders a black window otherwise).
    private var cachedAutoEnter: Bool = false
    // Cached so a rebuilt AVPictureInPictureController carries the same
    // linear-playback gate (used to hide AVKit's scrubber + 15s skip in
    // the PiP overlay for non-entitled users).
    private var cachedRequiresLinearPlayback: Bool = false
    private let enqueueQueue = DispatchQueue(
      label: "com.alexmercerind.media_kit_video.pip.enqueue",
      qos: .userInteractive
    )

    private var handle: Int64?
    private var isPlayingState: Bool = true
    private var startRequested: Bool = false
    private var firstFrameEnqueued: Bool = false
    private var startAttempts: Int = 0
    private var didRestoreInterface: Bool = false
    // Playback delegate state pushed from Dart via setMetadata.
    // Without these the time range falls back to ±∞ which iOS renders as
    // "LIVE" with stop button + greyed-out skip controls.
    private var contentDurationMs: Int64 = 0
    private var contentPositionMs: Int64 = 0
    // Deferred-rebuild flag. When PiP ends while the app is backgrounded,
    // recreating the display layer immediately produces a .failed layer (no GPU/Metal
    // access in background). Instead, set this flag and rebuild on the next
    // appDidBecomeActive when the rendering pipeline is alive.
    private var pendingRebuild: Bool = false
    // Where the restore animation should return the PiP window to — the video's
    // on-screen rect, pushed from Dart. Applied only at `willStop` so the active
    // session's layer stays 1×1 (no AVKit overlay-sublayer decoration); nil keeps
    // the 1×1-center collapse.
    private var restoreSourceRect: CGRect?

    init(
      hostView: UIView,
      outputManager: VideoOutputManager,
      videoSize: CGSize,
      eventCallback: @escaping EventCallback
    ) {
      self.hostView = hostView
      self.outputManager = outputManager
      self.eventCallback = eventCallback
      self.displayLayer = AVSampleBufferDisplayLayer()
      super.init()

      installDisplayLayer()

      NotificationCenter.default.addObserver(
        self,
        selector: #selector(appDidBecomeActive),
        name: UIApplication.didBecomeActiveNotification,
        object: nil
      )
    }

    deinit {
      NotificationCenter.default.removeObserver(self)
      teardown()
    }

    @objc private func appDidBecomeActive() {
      if pendingRebuild {
        pendingRebuild = false
        rebuildForNextSession()
      }

      guard let controller = pipController,
        controller.isPictureInPictureActive
      else { return }
      DispatchQueue.main.async {
        controller.stopPictureInPicture()
      }
    }

    var isActive: Bool {
      return pipController?.isPictureInPictureActive ?? false
    }

    @discardableResult
    func start(
      handle: Int64,
      autoEnter: Bool,
      startImmediately: Bool
    ) -> Bool {
      self.handle = handle
      self.cachedAutoEnter = autoEnter

      buildPipController(autoEnter: autoEnter)

      outputManager.setOnFrameRendered(handle: handle, key: "pip") { [weak self] pixelBuffer in
        self?.enqueue(pixelBuffer: pixelBuffer)
      }

      self.startRequested = startImmediately
      self.firstFrameEnqueued = false
      self.startAttempts = 0
      return true
    }

    private func installDisplayLayer() {
      displayLayer.videoGravity = .resizeAspect
      // Park the display layer at 1×1 in the host's center. AVKit reads this layer's
      // frame as the PiP exit-animation target; the center makes the
      // animation collapse inward rather than zip off to the top-left
      // corner. Keeping the rect at 1×1 means AVKit doesn't decorate the
      // layer with overlay sublayers (which it does when the display layer is sized
      // to a "real" viewing rect — those overlays leak into the parent
      // layer's sublayer list and survive the PiP session, polluting it).
      let center = CGPoint(x: hostView.bounds.midX, y: hostView.bounds.midY)
      displayLayer.frame = CGRect(x: center.x, y: center.y, width: 1, height: 1)
      displayLayer.isOpaque = false
      displayLayer.backgroundColor = UIColor.clear.cgColor
      hostView.layer.insertSublayer(displayLayer, at: 0)
    }

    private func buildPipController(autoEnter: Bool) {
      let contentSource = AVPictureInPictureController.ContentSource(
        sampleBufferDisplayLayer: displayLayer,
        playbackDelegate: self
      )
      let controller = AVPictureInPictureController(contentSource: contentSource)
      controller.delegate = self
      controller.canStartPictureInPictureAutomaticallyFromInline = autoEnter
      controller.requiresLinearPlayback = cachedRequiresLinearPlayback
      self.pipController = controller
    }

    /// After a PiP session ends (user closes or restores), the
    /// AVSampleBufferDisplayLayer is left in a state where iOS's next auto-
    /// enter renders a black window while audio keeps playing. Recreate the
    /// display layer and AVPictureInPictureController so subsequent sessions render.
    private func rebuildForNextSession() {
      guard let handle = handle else { return }
      outputManager.setOnFrameRendered(handle: handle, key: "pip", nil)

      displayLayer.flushAndRemoveImage()
      displayLayer.removeFromSuperlayer()
      displayLayer = AVSampleBufferDisplayLayer()
      installDisplayLayer()
      buildPipController(autoEnter: cachedAutoEnter)

      outputManager.setOnFrameRendered(handle: handle, key: "pip") { [weak self] pixelBuffer in
        self?.enqueue(pixelBuffer: pixelBuffer)
      }
    }

    private func attemptStart() {
      guard let controller = pipController else { return }
      if controller.isPictureInPictureActive { return }
      if controller.isPictureInPicturePossible {
        controller.startPictureInPicture()
        return
      }
      startAttempts += 1
      if startAttempts >= 20 {
        eventCallback(["event": "failed", "reason": "pip_not_possible"])
        return
      }
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
        self?.attemptStart()
      }
    }

    func stop() {
      if let controller = pipController, controller.isPictureInPictureActive {
        DispatchQueue.main.async { controller.stopPictureInPicture() }
      }
      teardown()
    }

    func setAutoEnter(_ enabled: Bool) {
      cachedAutoEnter = enabled
      pipController?.canStartPictureInPictureAutomaticallyFromInline = enabled
    }

    /// Hides AVKit's scrubber + 15s skip buttons in the PiP overlay when
    /// `true`. Used to gate seeking for non-entitled users so they can't
    /// bypass the in-app paywall via the PiP UI.
    func setRequiresLinearPlayback(_ required: Bool) {
      cachedRequiresLinearPlayback = required
      pipController?.requiresLinearPlayback = required
    }

    func setRestoreSourceRect(_ rect: CGRect?) {
      restoreSourceRect = rect
    }

    private func teardown() {
      if let handle = handle {
        outputManager.setOnFrameRendered(handle: handle, key: "pip", nil)
        self.handle = nil
      }
      pipController = nil
      displayLayer.flushAndRemoveImage()
      displayLayer.removeFromSuperlayer()
    }

    private func enqueue(pixelBuffer: CVPixelBuffer) {
      let retained = pixelBuffer
      enqueueQueue.async { [weak self] in
        guard let self = self else { return }
        // If the display layer has entered .failed (e.g., created in background,
        // decoder error), flush() resets the rendering state so the next
        // sample can populate the layer cleanly.
        if self.displayLayer.status == .failed {
          self.displayLayer.flush()
        }
        guard self.displayLayer.isReadyForMoreMediaData else { return }
        guard let sample = self.makeSampleBuffer(from: retained) else { return }
        self.displayLayer.enqueue(sample)
        if !self.firstFrameEnqueued {
          self.firstFrameEnqueued = true
          if self.startRequested {
            DispatchQueue.main.async { [weak self] in
              self?.attemptStart()
            }
          }
        }
      }
    }

    private func makeSampleBuffer(from pixelBuffer: CVPixelBuffer) -> CMSampleBuffer? {
      var formatDescription: CMVideoFormatDescription?
      let fdStatus = CMVideoFormatDescriptionCreateForImageBuffer(
        allocator: kCFAllocatorDefault,
        imageBuffer: pixelBuffer,
        formatDescriptionOut: &formatDescription
      )
      guard fdStatus == noErr, let description = formatDescription else { return nil }

      let presentationTime = CMClockGetTime(CMClockGetHostTimeClock())
      var timingInfo = CMSampleTimingInfo(
        duration: .invalid,
        presentationTimeStamp: presentationTime,
        decodeTimeStamp: .invalid
      )

      var sampleBuffer: CMSampleBuffer?
      let status = CMSampleBufferCreateReadyWithImageBuffer(
        allocator: kCFAllocatorDefault,
        imageBuffer: pixelBuffer,
        formatDescription: description,
        sampleTiming: &timingInfo,
        sampleBufferOut: &sampleBuffer
      )
      guard status == noErr, let buffer = sampleBuffer else { return nil }

      if let attachments = CMSampleBufferGetSampleAttachmentsArray(
        buffer,
        createIfNecessary: true
      ) as? [NSMutableDictionary],
        let first = attachments.first
      {
        first[kCMSampleAttachmentKey_DisplayImmediately as NSString] = kCFBooleanTrue
      }
      return buffer
    }
  }

  @available(iOS 15.0, *)
  extension MediaKitPictureInPictureController: AVPictureInPictureControllerDelegate {
    func pictureInPictureControllerWillStartPictureInPicture(
      _ controller: AVPictureInPictureController
    ) {
      eventCallback(["event": "willStart"])
    }

    func pictureInPictureControllerDidStartPictureInPicture(
      _ controller: AVPictureInPictureController
    ) {
      eventCallback(["event": "didStart"])
    }

    func pictureInPictureController(
      _ controller: AVPictureInPictureController,
      failedToStartPictureInPictureWithError error: Error
    ) {
      eventCallback(["event": "failed", "reason": error.localizedDescription])
    }

    func pictureInPictureControllerWillStopPictureInPicture(
      _ controller: AVPictureInPictureController
    ) {
      didRestoreInterface = false
      // Aim the restore animation at the on-screen video rect (fullscreen frame /
      // collapsed floating slot) instead of the 1×1 center point, so it doesn't read
      // as a shrink-to-black. Set frame-only (no implicit animation).
      if let rect = restoreSourceRect {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        displayLayer.frame = rect
        CATransaction.commit()
      }
      eventCallback(["event": "willStop"])
    }

    func pictureInPictureControllerDidStopPictureInPicture(
      _ controller: AVPictureInPictureController
    ) {
      if didRestoreInterface {
        eventCallback(["event": "didStop"])
      } else {
        eventCallback(["event": "closed"])
      }
      didRestoreInterface = false

      // Rebuilding the display layer in background produces a .failed layer (no GPU
      // access). Defer to appDidBecomeActive when active; run inline only if
      // we're already active (restore path).
      if UIApplication.shared.applicationState == .active {
        rebuildForNextSession()
      } else {
        pendingRebuild = true
      }
    }

    func pictureInPictureController(
      _ controller: AVPictureInPictureController,
      restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler:
        @escaping (Bool) -> Void
    ) {
      didRestoreInterface = true
      eventCallback(["event": "restore"])
      completionHandler(true)
    }
  }

  @available(iOS 15.0, *)
  extension MediaKitPictureInPictureController: AVPictureInPictureSampleBufferPlaybackDelegate {
    func pictureInPictureController(
      _ pipController: AVPictureInPictureController,
      setPlaying playing: Bool
    ) {
      isPlayingState = playing
      eventCallback(["event": "setPlaying", "playing": playing])
    }

    func pictureInPictureControllerTimeRangeForPlayback(
      _ pipController: AVPictureInPictureController
    ) -> CMTimeRange {
      // Return a real range for VOD so the PiP UI shows
      // pause (not stop) + enabled skip controls + correct progress bar.
      // Falls back to ±∞ (live-stream mode) when duration is unknown.
      guard contentDurationMs > 0 else {
        return CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
      }
      // Recipe from Apple's AVKit docs: anchor start at host clock minus
      // current position so the system can extrapolate position between
      // metadata pushes; this keeps the progress bar moving smoothly
      // without a 60 Hz update from Dart.
      let now = CMClockGetTime(CMClockGetHostTimeClock())
      let positionSeconds = Double(contentPositionMs) / 1000.0
      let positionTime = CMTime(seconds: positionSeconds, preferredTimescale: 1000)
      let start = CMTimeSubtract(now, positionTime)
      let duration = CMTime(value: contentDurationMs, timescale: 1000)
      return CMTimeRange(start: start, duration: duration)
    }

    func pictureInPictureControllerIsPlaybackPaused(
      _ pipController: AVPictureInPictureController
    ) -> Bool {
      return !isPlayingState
    }

    func pictureInPictureController(
      _ pipController: AVPictureInPictureController,
      didTransitionToRenderSize newRenderSize: CMVideoDimensions
    ) {
    }

    func pictureInPictureController(
      _ pipController: AVPictureInPictureController,
      skipByInterval skipInterval: CMTime,
      completion completionHandler: @escaping () -> Void
    ) {
      // Forward to Dart so the embedder can seek the player.
      // Without this the FF/RW buttons are no-ops even when enabled.
      let seconds = CMTimeGetSeconds(skipInterval)
      eventCallback(["event": "skipByInterval", "seconds": seconds])
      completionHandler()
    }
  }

  // Push playback metadata from Dart so the AVKit playback
  // delegate can return a real time range + pause state. See setMetadata
  // method-channel handler in MediaKitPictureInPicturePlugin.
  @available(iOS 15.0, *)
  extension MediaKitPictureInPictureController {
    func setMetadata(durationMs: Int64?, positionMs: Int64?, isPlaying: Bool?) {
      if let d = durationMs { contentDurationMs = d }
      if let p = positionMs { contentPositionMs = p }
      if let playing = isPlaying { isPlayingState = playing }
      // Nudge AVKit to re-query the delegate methods (otherwise stale
      // state can be cached for up to a second after metadata changes).
      pipController?.invalidatePlaybackState()
    }
  }
#endif
