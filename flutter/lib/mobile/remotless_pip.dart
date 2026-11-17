// Remotless: picture-in-picture viewer (the phone controlling a PC), Android and iOS.
//
// While a remote session is open the session page calls [RemotlessPip.configure] with the
// remote screen size. The session keeps running in a small floating window when the user leaves
// with Home (or taps Minimise); restoring it brings the full view back, and closing it ends the
// session ([onDismissed]).
//
// Android: MainActivity itself goes into PiP (mChannel messages set_pip / enter_pip).
// iOS: the app window can't shrink, so AppDelegate.swift shows the frames in an
// AVSampleBufferDisplayLayer PiP. Flutter can't draw in the background on iOS, so the raw BGRA
// frames from the Rust engine are passed to Swift ([onFrame]) before they are drawn.
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';

import '../common.dart';

class RemotlessPip {
  /// True while the session is shown in the small PiP window.
  static final inPip = false.obs;

  /// Whether this phone supports PiP (Android 8+ not switched off by the maker; iOS 15+).
  static final supported = false.obs;

  /// Called when the user closes the PiP window (drag away / X): end the session.
  static VoidCallback? onDismissed;

  static String _lastConfig = '';
  static bool _checkedSupport = false;
  static bool _enabled = false;

  static const _ios = MethodChannel('com.remotless/pip');
  static bool _iosHandlerSet = false;

  static void _ensureIosHandler() {
    if (!isIOS || _iosHandlerSet) return;
    _iosHandlerSet = true;
    _ios.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'onPipChanged':
          inPip.value = call.arguments == true;
          break;
        case 'onPipClosed':
          inPip.value = false;
          onDismissed?.call();
          break;
      }
      return null;
    });
  }

  static Future<void> checkSupport() async {
    if (_checkedSupport) return;
    try {
      if (isAndroid) {
        _checkedSupport = true;
        supported.value = (await gFFI.invokeMethod('is_pip_supported')) == true;
      } else if (isIOS) {
        _checkedSupport = true;
        _ensureIosHandler();
        supported.value = (await _ios.invokeMethod('isSupported')) == true;
      }
    } catch (e) {
      debugPrint('RemotlessPip: support check failed: $e');
    }
  }

  /// Turns PiP on (with the remote screen's aspect ratio) or off. Repeated calls with the
  /// same values are ignored, so this can be called from build().
  static Future<void> configure(
      {required bool enabled, int width = 0, int height = 0}) async {
    if (!isAndroid && !isIOS) return;
    final key = '$enabled:$width:$height';
    if (key == _lastConfig) return;
    _lastConfig = key;
    _enabled = enabled;
    try {
      if (isAndroid) {
        await gFFI.invokeMethod(
            'set_pip', {'enabled': enabled, 'w': width, 'h': height});
      } else {
        _ensureIosHandler();
        await _ios.invokeMethod('setEnabled', enabled);
      }
    } catch (e) {
      debugPrint('RemotlessPip: configure failed: $e');
    }
  }

  /// Shrinks the session into the PiP window now (the Minimise button).
  static Future<bool> enter() async {
    try {
      if (isAndroid) return (await gFFI.invokeMethod('enter_pip')) == true;
      if (isIOS) return (await _ios.invokeMethod('start')) == true;
    } catch (e) {
      debugPrint('RemotlessPip: enter failed: $e');
    }
    return false;
  }

  static int _lastFrameMs = 0;

  /// iOS only: called for every remote frame (BGRA) before it is drawn. The bytes belong to the
  /// Rust engine and are reused afterwards; invokeMethod encodes (copies) them synchronously.
  /// About 1 frame a second keeps the PiP layer ready while the session is full screen, about
  /// 6 a second while it is in the PiP window.
  static void onFrame(Uint8List bgra, int width, int height) {
    if (!isIOS || !_enabled || width <= 0 || height <= 0) return;
    if (bgra.length < width * height * 4) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _lastFrameMs < (inPip.value ? 160 : 1000)) return;
    _lastFrameMs = now;
    _ios.invokeMethod('pushFrame', {'w': width, 'h': height, 'data': bgra});
  }

  /// Messages from MainActivity (see androidChannelInit). Returns true when handled.
  static bool handleAndroidMessage(String method, dynamic arguments) {
    switch (method) {
      case 'on_pip_changed':
        inPip.value = (arguments is Map) && arguments['in_pip'] == true;
        return true;
      case 'on_pip_dismissed':
        inPip.value = false;
        onDismissed?.call();
        return true;
    }
    return false;
  }
}
