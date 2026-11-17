import UIKit
import Flutter
import AVFoundation
import AVKit
import CoreMedia

@main
@objc class AppDelegate: FlutterAppDelegate {
  // Remotless: picture-in-picture for remote sessions (see RemotlessPip below).
  private var remotlessPip: RemotlessPip?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    do {
      // Mix remote audio with other apps while still respecting silent mode.
      try AVAudioSession.sharedInstance().setCategory(.ambient)
    } catch {
      NSLog("Failed to configure audio mixing: %@", error.localizedDescription)
    }
    dummyMethodToEnforceBundling();
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  // With the UIScene life cycle, the FlutterViewController only exists once the scene
  // connects, and FlutterAppDelegate reaches its engine through `window`. A launch URL
  // also arrives with the scene instead of in launchOptions, so forward it to plugins here.
  func sceneWillConnect(window: UIWindow?, launchURL: URL?) {
    self.window = window
    GeneratedPluginRegistrant.register(with: self)
    var launchOptions: [UIApplication.LaunchOptionsKey: Any] = [:]
    if let launchURL = launchURL {
      launchOptions[.url] = launchURL
    }
    _ = super.application(UIApplication.shared, didFinishLaunchingWithOptions: launchOptions)
    if remotlessPip == nil, let flutterVC = window?.rootViewController as? FlutterViewController {
      let channel = FlutterMethodChannel(
        name: "com.remotless/pip", binaryMessenger: flutterVC.binaryMessenger)
      remotlessPip = RemotlessPip(channel: channel, hostIn: flutterVC.view)
    }
  }
    
  public func dummyMethodToEnforceBundling() {
      dummy_method_to_enforce_bundling();
    session_get_rgba(nil, 0);
  }
}

// MARK: - Remotless picture-in-picture

/// Shows the remote screen in iOS picture-in-picture while the phone controls a computer.
/// iOS can't shrink an app window, so the frames go into an AVSampleBufferDisplayLayer that
/// AVKit shows as PiP. Dart sends the raw BGRA frames from the Rust engine ("pushFrame"),
/// because Flutter can't draw while the app is in the background.
///
/// Channel com.remotless/pip:
///   Dart -> iOS: isSupported, setEnabled(Bool), pushFrame({w, h, data}), start, stop
///   iOS -> Dart: onPipChanged(Bool), onPipClosed (the user closed the PiP window: end the session)
final class RemotlessPip: NSObject, AVPictureInPictureControllerDelegate,
  AVPictureInPictureSampleBufferPlaybackDelegate
{
  private let channel: FlutterMethodChannel
  private let hostView = UIView()
  private let displayLayer = AVSampleBufferDisplayLayer()
  private var controller: AVPictureInPictureController?
  private var enabled = false
  private var restoring = false

  init(channel: FlutterMethodChannel, hostIn view: UIView) {
    self.channel = channel
    super.init()
    // AVKit needs the layer in the view hierarchy; keep it tiny and out of the way.
    hostView.frame = CGRect(x: 0, y: 0, width: 2, height: 2)
    hostView.isUserInteractionEnabled = false
    hostView.alpha = 0.01
    displayLayer.frame = hostView.bounds
    displayLayer.videoGravity = .resizeAspect
    hostView.layer.addSublayer(displayLayer)
    view.addSubview(hostView)

    if AVPictureInPictureController.isPictureInPictureSupported() {
      let source = AVPictureInPictureController.ContentSource(
        sampleBufferDisplayLayer: displayLayer, playbackDelegate: self)
      let pip = AVPictureInPictureController(contentSource: source)
      pip.delegate = self
      pip.requiresLinearPlayback = true
      pip.canStartPictureInPictureAutomaticallyFromInline = false
      controller = pip
    }
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else {
        result(nil)
        return
      }
      self.handle(call, result: result)
    }
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "isSupported":
      result(controller != nil)
    case "setEnabled":
      setEnabled(call.arguments as? Bool ?? false)
      result(true)
    case "pushFrame":
      if let args = call.arguments as? [String: Any],
        let w = args["w"] as? Int, let h = args["h"] as? Int,
        let data = args["data"] as? FlutterStandardTypedData
      {
        enqueue(width: w, height: h, bgra: data.data)
      }
      result(nil)
    case "start":
      guard enabled, let pip = controller, pip.isPictureInPicturePossible else {
        result(false)
        return
      }
      pip.startPictureInPicture()
      result(true)
    case "stop":
      controller?.stopPictureInPicture()
      result(true)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func setEnabled(_ on: Bool) {
    enabled = on
    // Swiping home goes straight into PiP while a session is open.
    controller?.canStartPictureInPictureAutomaticallyFromInline = on
    // PiP needs a playback audio session; mix with other apps so their sound keeps playing.
    do {
      if on {
        try AVAudioSession.sharedInstance().setCategory(.playback, options: [.mixWithOthers])
      } else {
        try AVAudioSession.sharedInstance().setCategory(.ambient)
      }
    } catch {
      NSLog("Remotless PiP: audio session: %@", error.localizedDescription)
    }
    if !on {
      if controller?.isPictureInPictureActive == true { controller?.stopPictureInPicture() }
      displayLayer.flushAndRemoveImage()
    }
  }

  private func enqueue(width: Int, height: Int, bgra: Data) {
    guard enabled, width > 0, height > 0, bgra.count >= width * height * 4 else { return }
    var pixelBuffer: CVPixelBuffer?
    let attrs: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
    guard
      CVPixelBufferCreate(
        kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
        attrs as CFDictionary, &pixelBuffer) == kCVReturnSuccess,
      let pb = pixelBuffer
    else { return }
    CVPixelBufferLockBaseAddress(pb, [])
    if let dst = CVPixelBufferGetBaseAddress(pb) {
      let dstStride = CVPixelBufferGetBytesPerRow(pb)
      let srcStride = width * 4
      bgra.withUnsafeBytes { (src: UnsafeRawBufferPointer) in
        guard let srcBase = src.baseAddress else { return }
        for row in 0..<height {
          memcpy(dst + row * dstStride, srcBase + row * srcStride, srcStride)
        }
      }
    }
    CVPixelBufferUnlockBaseAddress(pb, [])

    var format: CMVideoFormatDescription?
    guard
      CMVideoFormatDescriptionCreateForImageBuffer(
        allocator: kCFAllocatorDefault, imageBuffer: pb, formatDescriptionOut: &format) == noErr,
      let fmt = format
    else { return }
    var timing = CMSampleTimingInfo(
      duration: .invalid, presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
      decodeTimeStamp: .invalid)
    var sample: CMSampleBuffer?
    guard
      CMSampleBufferCreateReadyWithImageBuffer(
        allocator: kCFAllocatorDefault, imageBuffer: pb, formatDescription: fmt,
        sampleTiming: &timing, sampleBufferOut: &sample) == noErr,
      let sb = sample
    else { return }
    if let attachments = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: true),
      CFArrayGetCount(attachments) > 0
    {
      let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
      CFDictionarySetValue(
        dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
        Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
    }
    if displayLayer.status == .failed { displayLayer.flush() }
    displayLayer.enqueue(sb)
  }

  // MARK: AVPictureInPictureSampleBufferPlaybackDelegate (a live stream: no pause, no seeking)

  func pictureInPictureController(
    _ pictureInPictureController: AVPictureInPictureController, setPlaying playing: Bool
  ) {}

  func pictureInPictureControllerTimeRangeForPlayback(
    _ pictureInPictureController: AVPictureInPictureController
  ) -> CMTimeRange {
    CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
  }

  func pictureInPictureControllerIsPlaybackPaused(
    _ pictureInPictureController: AVPictureInPictureController
  ) -> Bool { false }

  func pictureInPictureController(
    _ pictureInPictureController: AVPictureInPictureController,
    didTransitionToRenderSize newRenderSize: CMVideoDimensions
  ) {}

  func pictureInPictureController(
    _ pictureInPictureController: AVPictureInPictureController,
    skipByInterval skipInterval: CMTime, completion completionHandler: @escaping () -> Void
  ) { completionHandler() }

  // MARK: AVPictureInPictureControllerDelegate

  func pictureInPictureControllerWillStartPictureInPicture(
    _ pictureInPictureController: AVPictureInPictureController
  ) {
    restoring = false
    channel.invokeMethod("onPipChanged", arguments: true)
  }

  func pictureInPictureController(
    _ pictureInPictureController: AVPictureInPictureController,
    restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler:
      @escaping (Bool) -> Void
  ) {
    // The user tapped "back to app" (or opened the app): keep the session.
    restoring = true
    completionHandler(true)
  }

  func pictureInPictureControllerDidStopPictureInPicture(
    _ pictureInPictureController: AVPictureInPictureController
  ) {
    channel.invokeMethod("onPipChanged", arguments: false)
    // Closed with the X (no restore): end the session, as on Android.
    if !restoring { channel.invokeMethod("onPipClosed", arguments: nil) }
    restoring = false
  }

  func pictureInPictureController(
    _ pictureInPictureController: AVPictureInPictureController,
    failedToStartPictureInPictureWithError error: Error
  ) {
    NSLog("Remotless PiP failed to start: %@", error.localizedDescription)
    channel.invokeMethod("onPipChanged", arguments: false)
  }
}
