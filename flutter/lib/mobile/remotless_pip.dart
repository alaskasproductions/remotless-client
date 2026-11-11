// Remotless: picture-in-picture viewer for Android (the phone controlling a PC).
//
// While a remote session is open the session page calls [RemotlessPip.configure] with the
// remote screen size. MainActivity then enters PiP when the user leaves with Home (or taps
// Minimise): the session keeps running in a small floating window, tapping it brings the full
// view back, and dragging it away ends the session ([onDismissed]).
import 'package:flutter/foundation.dart';
import 'package:get/get.dart';

import '../common.dart';

class RemotlessPip {
  /// True while the app is shown as the small PiP window.
  static final inPip = false.obs;

  /// Whether this phone supports PiP (Android 8+ and not switched off by the maker).
  static final supported = false.obs;

  /// Called when the user closes the PiP window (drag away / X): end the session.
  static VoidCallback? onDismissed;

  static String _lastConfig = '';
  static bool _checkedSupport = false;

  static Future<void> checkSupport() async {
    if (!isAndroid || _checkedSupport) return;
    _checkedSupport = true;
    try {
      supported.value = (await gFFI.invokeMethod('is_pip_supported')) == true;
    } catch (e) {
      debugPrint('RemotlessPip: is_pip_supported failed: $e');
    }
  }

  /// Turns PiP on (with the remote screen's aspect ratio) or off. Repeated calls with the
  /// same values are ignored, so this can be called from build().
  static Future<void> configure(
      {required bool enabled, int width = 0, int height = 0}) async {
    if (!isAndroid) return;
    final key = '$enabled:$width:$height';
    if (key == _lastConfig) return;
    _lastConfig = key;
    try {
      await gFFI.invokeMethod(
          'set_pip', {'enabled': enabled, 'w': width, 'h': height});
    } catch (e) {
      debugPrint('RemotlessPip: set_pip failed: $e');
    }
  }

  /// Shrinks the session into the PiP window now (the Minimise button).
  static Future<bool> enter() async {
    if (!isAndroid) return false;
    try {
      return (await gFFI.invokeMethod('enter_pip')) == true;
    } catch (e) {
      debugPrint('RemotlessPip: enter_pip failed: $e');
      return false;
    }
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
