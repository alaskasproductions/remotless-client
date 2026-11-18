import Flutter
import ReplayKit
import UIKit
import UserNotifications

/// Remotless: the app's half of iPhone/iPad screen sharing (view only). The sharing itself runs
/// in the RemotlessBroadcast extension; this class passes settings and the user's answers to it
/// through the App Group, and its state back to Dart. See docs/ios-screen-share.md.
///
/// Channel com.remotless/share_screen:
///   Dart -> iOS: isSupported, writeConfig(String json), readState -> String,
///                command({cmd, id}), startBroadcast, requestNotifications
///   iOS -> Dart: onState(String json) whenever the extension updates its state
final class RemotlessShareScreen: NSObject {
  static let appGroup = "group.com.remotless.app"
  static let extensionBundleId = "com.remotless.app.broadcast"
  private static let notifyState = "com.remotless.app.share.state"
  private static let notifyCommand = "com.remotless.app.share.command"
  private static let notifyConfig = "com.remotless.app.share.config"

  private let channel: FlutterMethodChannel
  private weak var hostView: UIView?
  private var picker: RPSystemBroadcastPickerView?
  private var commandSeq = Int(Date().timeIntervalSince1970 * 1000)

  init(channel: FlutterMethodChannel, hostIn view: UIView) {
    self.channel = channel
    self.hostView = view
    super.init()
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else {
        result(nil)
        return
      }
      self.handle(call, result: result)
    }
    CFNotificationCenterAddObserver(
      CFNotificationCenterGetDarwinNotifyCenter(),
      Unmanaged.passUnretained(self).toOpaque(),
      { _, observer, _, _, _ in
        guard let observer = observer else { return }
        let me = Unmanaged<RemotlessShareScreen>.fromOpaque(observer).takeUnretainedValue()
        DispatchQueue.main.async { me.pushState() }
      },
      RemotlessShareScreen.notifyState as CFString, nil, .deliverImmediately)
  }

  deinit {
    CFNotificationCenterRemoveEveryObserver(
      CFNotificationCenterGetDarwinNotifyCenter(), Unmanaged.passUnretained(self).toOpaque())
  }

  private var shareDir: URL? {
    guard
      let container = FileManager.default.containerURL(
        forSecurityApplicationGroupIdentifier: RemotlessShareScreen.appGroup)
    else { return nil }
    let dir = container.appendingPathComponent("share", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "isSupported":
      result(shareDir != nil)
    case "writeConfig":
      guard let dir = shareDir, let json = call.arguments as? String else {
        result(false)
        return
      }
      do {
        try json.write(
          to: dir.appendingPathComponent("share.json"), atomically: true, encoding: .utf8)
        post(RemotlessShareScreen.notifyConfig)
        result(true)
      } catch {
        result(false)
      }
    case "readState":
      result(readState())
    case "command":
      guard let dir = shareDir, let args = call.arguments as? [String: Any],
        let cmd = args["cmd"] as? String
      else {
        result(false)
        return
      }
      commandSeq += 1
      let obj: [String: Any] = ["seq": commandSeq, "cmd": cmd, "id": args["id"] as? Int ?? 0]
      if let data = try? JSONSerialization.data(withJSONObject: obj),
        (try? data.write(to: dir.appendingPathComponent("command.json"), options: .atomic))
          != nil
      {
        post(RemotlessShareScreen.notifyCommand)
        result(true)
      } else {
        result(false)
      }
    case "startBroadcast":
      result(showPicker())
    case "requestNotifications":
      UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) {
        granted, _ in
        DispatchQueue.main.async { result(granted) }
      }
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func readState() -> String {
    guard let dir = shareDir,
      let s = try? String(contentsOf: dir.appendingPathComponent("state.json"))
    else { return "" }
    return s
  }

  private func pushState() {
    channel.invokeMethod("onState", arguments: readState())
  }

  private func post(_ name: String) {
    CFNotificationCenterPostNotification(
      CFNotificationCenterGetDarwinNotifyCenter(), CFNotificationName(name as CFString), nil,
      nil, true)
  }

  /// Opens the system "Screen Broadcast" sheet with Remotless preselected. iOS only lets the
  /// user start a broadcast from this system button, so we tap it for them.
  private func showPicker() -> Bool {
    guard let view = hostView else { return false }
    if picker == nil {
      let p = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
      p.preferredExtension = RemotlessShareScreen.extensionBundleId
      p.showsMicrophoneButton = false
      p.alpha = 0.01
      p.isUserInteractionEnabled = false
      view.addSubview(p)
      picker = p
    }
    guard let button = picker?.subviews.compactMap({ $0 as? UIButton }).first else {
      return false
    }
    button.sendActions(for: .touchUpInside)
    return true
  }
}
