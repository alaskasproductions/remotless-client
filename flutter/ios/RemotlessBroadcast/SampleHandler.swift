// Remotless: the ReplayKit Broadcast Upload Extension that shares the iPhone/iPad screen
// (view only) with a technician. See docs/ios-screen-share.md.
//
// The whole Remotless server runs here, not in the app: iOS suspends the app a few seconds
// after the user leaves it, while this extension lives as long as the broadcast. It links the
// same Rust library as the app (src/ios_broadcast.rs) and talks to the app through the App
// Group container (share.json, state.json, command.json) and Darwin notifications.
//
// Memory limit: about 50 MB. Frames are throttled to 15 fps and scaled down to 1280 px on the
// long side before they are converted, with buffers allocated once.

import Accelerate
import CoreMedia
import ReplayKit
import UserNotifications

private let appGroup = "group.com.remotless.app"
private let notifyState = "com.remotless.app.share.state"
private let notifyCommand = "com.remotless.app.share.command"
private let notifyConfig = "com.remotless.app.share.config"
/// A technician without the one-time password waits this long for the user's answer.
private let acceptTimeout: TimeInterval = 60
/// Lower this (e.g. 960) if the extension gets killed for memory on some devices.
private let maxLongSide = 1280
private let minFrameInterval: CFTimeInterval = 1.0 / 15.0

/// Rust calls this from its own threads with one JSON event.
private let remotlessEvent: RemotlessEventCallback = { ptr in
  guard let ptr = ptr else { return }
  let text = String(cString: ptr)
  SampleHandler.current?.handleEvent(text)
}

final class SampleHandler: RPBroadcastSampleHandler {
  fileprivate static weak var current: SampleHandler?

  private var shareDir: URL?
  private let queue = DispatchQueue(label: "com.remotless.share.events")
  private let scaler = FrameScaler(maxLongSide: maxLongSide)
  private var lastFrameTime: CFTimeInterval = 0
  // Guarded by `queue`.
  private var clients: [Int: [String: Any]] = [:]
  private var registeredId = ""
  private var lastError = ""
  private var lastCommandSeq = -1
  private var timeouts: [Int: DispatchWorkItem] = [:]
  private var sharing = false

  override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
    SampleHandler.current = self
    guard
      let container = FileManager.default.containerURL(
        forSecurityApplicationGroupIdentifier: appGroup)
    else {
      stop("Remotless can't reach its shared folder. Reinstall the app and try again.")
      return
    }
    let dir = container.appendingPathComponent("share", isDirectory: true)
    let extDir = dir.appendingPathComponent("ext", isDirectory: true)
    try? FileManager.default.createDirectory(at: extDir, withIntermediateDirectories: true)
    shareDir = dir
    // Commands written before this broadcast don't apply to it.
    lastCommandSeq = readCommand()?.seq ?? -1
    observe(notifyCommand)
    observe(notifyConfig)
    let shareJson = (try? String(contentsOf: dir.appendingPathComponent("share.json"))) ?? "{}"
    queue.sync {
      sharing = true
      registeredId = ""
      lastError = ""
      clients = [:]
    }
    let rc = remotless_bc_start(extDir.path, shareJson, remotlessEvent)
    if rc < 0 {
      stop("Open Remotless and tap Share screen first.")
      return
    }
    writeState()
  }

  override func broadcastPaused() {}

  override func broadcastResumed() {}

  override func broadcastFinished() {
    remotless_bc_stop()
    CFNotificationCenterRemoveEveryObserver(
      CFNotificationCenterGetDarwinNotifyCenter(), Unmanaged.passUnretained(self).toOpaque())
    queue.sync {
      sharing = false
      clients = [:]
      timeouts.values.forEach { $0.cancel() }
      timeouts = [:]
    }
    writeState()
  }

  override func processSampleBuffer(
    _ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType
  ) {
    guard sampleBufferType == .video else { return }
    let now = CACurrentMediaTime()
    if now - lastFrameTime < minFrameInterval { return }
    lastFrameTime = now
    guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
    var orientation = CGImagePropertyOrientation.up
    if let raw = CMGetAttachment(
      sampleBuffer, key: RPVideoSampleOrientationKey as CFString, attachmentModeOut: nil)
      as? NSNumber, let o = CGImagePropertyOrientation(rawValue: raw.uint32Value)
    {
      orientation = o
    }
    scaler.process(pixelBuffer, orientation: orientation) { data, len, width, height, stride in
      remotless_bc_push_frame(
        data.assumingMemoryBound(to: UInt8.self), len, UInt32(width), UInt32(height),
        UInt32(stride))
    }
  }

  // MARK: Events from Rust

  fileprivate func handleEvent(_ text: String) {
    guard let data = text.data(using: .utf8),
      let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let name = event["name"] as? String
    else { return }
    queue.async {
      switch name {
      case "started":
        self.registeredId = event["id"] as? String ?? ""
      case "add_connection":
        guard let client = event["client"] as? [String: Any],
          let id = (client["id"] as? NSNumber)?.intValue
        else { return }
        self.clients[id] = client
        if (client["authorized"] as? Bool) != true {
          self.waitForAnswer(id: id, client: client)
        }
      case "remove_connection":
        if let id = (event["id"] as? NSNumber)?.intValue {
          self.clients.removeValue(forKey: id)
          self.timeouts.removeValue(forKey: id)?.cancel()
        }
      case "error":
        self.lastError = event["text"] as? String ?? ""
      default:
        return
      }
      self.writeStateLocked()
    }
  }

  /// Someone connected without the password: the user must accept in the app.
  private func waitForAnswer(id: Int, client: [String: Any]) {
    let work = DispatchWorkItem { [weak self] in
      guard let self = self, self.clients[id] != nil else { return }
      remotless_bc_authorize(Int32(id), false)
      self.clients.removeValue(forKey: id)
      self.timeouts.removeValue(forKey: id)
      self.writeStateLocked()
    }
    timeouts[id] = work
    queue.asyncAfter(deadline: .now() + acceptTimeout, execute: work)
    // The app may be in the background: a notification brings the user back to answer.
    let content = UNMutableNotificationContent()
    let who = (client["name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    let peer = client["peer_id"] as? String ?? ""
    content.title = "Someone wants to see your screen"
    content.body =
      "\(who ?? "Remotless ID \(peer)") asks to see your screen. Open Remotless to allow or deny."
    content.sound = .default
    content.userInfo = ["remotless_share_request": id]
    let request = UNNotificationRequest(
      identifier: "remotless-share-\(id)", content: content, trigger: nil)
    UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
  }

  // MARK: App -> extension

  private func observe(_ name: String) {
    CFNotificationCenterAddObserver(
      CFNotificationCenterGetDarwinNotifyCenter(),
      Unmanaged.passUnretained(self).toOpaque(),
      { _, observer, name, _, _ in
        guard let observer = observer, let name = name?.rawValue as String? else { return }
        let me = Unmanaged<SampleHandler>.fromOpaque(observer).takeUnretainedValue()
        me.handleNotification(name)
      },
      name as CFString, nil, .deliverImmediately)
  }

  private func handleNotification(_ name: String) {
    queue.async { self.handleNotificationLocked(name) }
  }

  /// Call on `queue`.
  private func handleNotificationLocked(_ name: String) {
    if name == notifyConfig {
      guard let dir = shareDir,
        let json = try? String(contentsOf: dir.appendingPathComponent("share.json"))
      else { return }
      // Already running: applies the new password and settings.
      _ = remotless_bc_start(dir.appendingPathComponent("ext").path, json, remotlessEvent)
      return
    }
    guard name == notifyCommand, let cmd = readCommand(), cmd.seq > lastCommandSeq else { return }
    lastCommandSeq = cmd.seq
    switch cmd.cmd {
    case "authorize", "deny":
      let accept = cmd.cmd == "authorize"
      remotless_bc_authorize(Int32(cmd.id), accept)
      timeouts.removeValue(forKey: cmd.id)?.cancel()
      if accept {
        clients[cmd.id]?["authorized"] = true
      } else {
        clients.removeValue(forKey: cmd.id)
      }
      writeStateLocked()
      UNUserNotificationCenter.current().removeDeliveredNotifications(
        withIdentifiers: ["remotless-share-\(cmd.id)"])
    case "disconnect":
      remotless_bc_disconnect_all()
    case "stop":
      stop("Screen sharing stopped.")
    default:
      break
    }
  }

  private struct Command {
    let seq: Int
    let cmd: String
    let id: Int
  }

  private func readCommand() -> Command? {
    guard let dir = shareDir,
      let data = try? Data(contentsOf: dir.appendingPathComponent("command.json")),
      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let seq = (obj["seq"] as? NSNumber)?.intValue
    else { return nil }
    return Command(
      seq: seq, cmd: obj["cmd"] as? String ?? "", id: (obj["id"] as? NSNumber)?.intValue ?? 0)
  }

  private func stop(_ message: String) {
    let error = NSError(
      domain: "com.remotless.app.broadcast", code: 1,
      userInfo: [NSLocalizedDescriptionKey: message])
    finishBroadcastWithError(error)
  }

  // MARK: Extension -> app

  private func writeState() {
    queue.async { self.writeStateLocked() }
  }

  /// Call on `queue`.
  private func writeStateLocked() {
    guard let dir = shareDir else { return }
    let list = clients.keys.sorted().compactMap { id -> [String: Any]? in
      guard let c = clients[id] else { return nil }
      return [
        "id": id,
        "peer_id": c["peer_id"] as? String ?? "",
        "name": c["name"] as? String ?? "",
        "authorized": c["authorized"] as? Bool ?? false,
      ]
    }
    let state: [String: Any] = [
      "sharing": sharing,
      "id": registeredId,
      "clients": list,
      "error": lastError,
      "updated": Date().timeIntervalSince1970,
    ]
    if let data = try? JSONSerialization.data(withJSONObject: state) {
      try? data.write(to: dir.appendingPathComponent("state.json"), options: .atomic)
    }
    CFNotificationCenterPostNotification(
      CFNotificationCenterGetDarwinNotifyCenter(), CFNotificationName(notifyState as CFString),
      nil, nil, true)
  }
}

/// Scales a ReplayKit frame (420f/420v NV12) down and converts it to upright BGRA with
/// vImage. The planes are scaled first, so no full-resolution RGB copy is ever made.
/// Buffers are reused while the size stays the same.
final class FrameScaler {
  private let maxLongSide: Int
  private var srcWidth = 0
  private var srcHeight = 0
  private var fullRange = true
  private var y = vImage_Buffer()
  private var cbcr = vImage_Buffer()
  private var bgra = vImage_Buffer()
  private var rotated = vImage_Buffer()
  private var info = vImage_YpCbCrToARGB()
  private var ready = false

  init(maxLongSide: Int) {
    self.maxLongSide = maxLongSide
  }

  deinit { free() }

  private func free() {
    for b in [y, cbcr, bgra, rotated] where b.data != nil {
      b.data.deallocate()
    }
    y = vImage_Buffer()
    cbcr = vImage_Buffer()
    bgra = vImage_Buffer()
    rotated = vImage_Buffer()
    ready = false
  }

  private static func alloc(
    width: Int, height: Int, bytesPerPixel: Int, minBytes: Int = 0
  ) -> vImage_Buffer {
    let rowBytes = (width * bytesPerPixel + 63) & ~63
    let data = UnsafeMutableRawPointer.allocate(
      byteCount: max(rowBytes * height, minBytes), alignment: 64)
    return vImage_Buffer(
      data: data, height: vImagePixelCount(height), width: vImagePixelCount(width),
      rowBytes: rowBytes)
  }

  private func setUp(width: Int, height: Int, fullRange: Bool) -> Bool {
    free()
    let scale = min(1.0, Double(maxLongSide) / Double(max(width, height)))
    // Even sizes: the chroma plane is half the size of the luma plane.
    let w = max(2, Int(Double(width) * scale) & ~1)
    let h = max(2, Int(Double(height) * scale) & ~1)
    y = FrameScaler.alloc(width: w, height: h, bytesPerPixel: 1)
    cbcr = FrameScaler.alloc(width: w / 2, height: h / 2, bytesPerPixel: 2)
    bgra = FrameScaler.alloc(width: w, height: h, bytesPerPixel: 4)
    // Also holds the 180-degree turn, which keeps the BGRA layout.
    rotated = FrameScaler.alloc(
      width: h, height: w, bytesPerPixel: 4, minBytes: bgra.rowBytes * h)
    var range =
      fullRange
      ? vImage_YpCbCrPixelRange(
        Yp_bias: 0, CbCr_bias: 128, YpRangeMax: 255, CbCrRangeMax: 255, YpMax: 255, YpMin: 0,
        CbCrMax: 255, CbCrMin: 0)
      : vImage_YpCbCrPixelRange(
        Yp_bias: 16, CbCr_bias: 128, YpRangeMax: 235, CbCrRangeMax: 240, YpMax: 235, YpMin: 16,
        CbCrMax: 240, CbCrMin: 16)
    let err = vImageConvert_YpCbCrToARGB_GenerateConversion(
      kvImage_YpCbCrToARGBMatrix_ITU_R_709_2, &range, &info, kvImage420Yp8_CbCr8,
      kvImageARGB8888, vImage_Flags(kvImageNoFlags))
    srcWidth = width
    srcHeight = height
    self.fullRange = fullRange
    ready = err == kvImageNoError
    return ready
  }

  func process(
    _ pixelBuffer: CVPixelBuffer, orientation: CGImagePropertyOrientation,
    output: (UnsafeRawPointer, Int, Int, Int, Int) -> Void
  ) {
    let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
    let isFull = format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
    guard isFull || format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
      CVPixelBufferGetPlaneCount(pixelBuffer) == 2
    else { return }
    let width = CVPixelBufferGetWidth(pixelBuffer)
    let height = CVPixelBufferGetHeight(pixelBuffer)
    if !ready || width != srcWidth || height != srcHeight || isFull != fullRange {
      guard setUp(width: width, height: height, fullRange: isFull) else { return }
    }
    CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
    guard let yBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0),
      let cBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1)
    else { return }
    var ySrc = vImage_Buffer(
      data: yBase, height: vImagePixelCount(CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)),
      width: vImagePixelCount(CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)),
      rowBytes: CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0))
    var cSrc = vImage_Buffer(
      data: cBase, height: vImagePixelCount(CVPixelBufferGetHeightOfPlane(pixelBuffer, 1)),
      width: vImagePixelCount(CVPixelBufferGetWidthOfPlane(pixelBuffer, 1)),
      rowBytes: CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1))
    let flags = vImage_Flags(kvImageNoFlags)
    guard vImageScale_Planar8(&ySrc, &y, nil, flags) == kvImageNoError,
      vImageScale_CbCr8(&cSrc, &cbcr, nil, flags) == kvImageNoError
    else { return }
    // ARGB8888 channel order permuted to BGRA in memory, which is what Rust expects.
    var permute: [UInt8] = [3, 2, 1, 0]
    guard
      vImageConvert_420Yp8_CbCr8ToARGB8888(&y, &cbcr, &bgra, &info, &permute, 255, flags)
        == kvImageNoError
    else { return }
    // ReplayKit always delivers portrait buffers; turn them so the technician sees the
    // screen the way the user holds the phone.
    let rotation: Int?
    switch orientation {
    case .left, .leftMirrored: rotation = kRotate90DegreesCounterClockwise
    case .right, .rightMirrored: rotation = kRotate90DegreesClockwise
    case .down, .downMirrored: rotation = kRotate180DegreesClockwise
    default: rotation = nil
    }
    if let r = rotation {
      var out = rotated
      if r == kRotate180DegreesClockwise {
        out = vImage_Buffer(
          data: rotated.data, height: bgra.height, width: bgra.width, rowBytes: bgra.rowBytes)
      }
      var black: [UInt8] = [0, 0, 0, 255]
      guard vImageRotate90_ARGB8888(&bgra, &out, UInt8(r), &black, flags) == kvImageNoError
      else { return }
      output(UnsafeRawPointer(out.data), out.rowBytes * Int(out.height), Int(out.width),
        Int(out.height), out.rowBytes)
    } else {
      output(UnsafeRawPointer(bgra.data), bgra.rowBytes * Int(bgra.height), Int(bgra.width),
        Int(bgra.height), bgra.rowBytes)
    }
  }
}
