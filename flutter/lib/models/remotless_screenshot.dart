// Remotless: take one screenshot of the remote screen for "Ask about this screen" (AI panel).
// Uses the app's own screenshot feature (the remote PC captures it and sends a PNG back), so it
// works with every render mode. While a request is pending, the result is caught here instead of
// showing the "Save as / Copy" dialog, shrunk to at most 1280 px wide and returned as PNG bytes.
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/consts.dart';
import 'package:flutter_hbb/models/model.dart';
import 'package:flutter_hbb/models/platform_model.dart';

class RemotlessScreenshot {
  static final Map<String, Completer<Uint8List>> _pending = {};

  /// Throws a readable message on failure.
  static Future<Uint8List> take(FFI ffi) async {
    final display = ffi.ffiModel.pi.currentDisplay;
    if (display == kAllDisplayValue) {
      throw 'Show one screen of the other computer first (toolbar → Display), then try again.';
    }
    final key = ffi.sessionId.toString();
    if (_pending.containsKey(key)) throw 'A picture is already being taken.';
    final c = Completer<Uint8List>();
    _pending[key] = c;
    try {
      bind.sessionTakeScreenshot(sessionId: ffi.sessionId, display: display);
      final png = await c.future.timeout(const Duration(seconds: 25),
          onTimeout: () => throw 'The other computer did not send a picture. Try again.');
      return await _shrink(png);
    } finally {
      _pending.remove(key);
    }
  }

  /// Called first by the session's screenshot event handler. Returns true when handled here.
  static bool handle(SessionID sessionId, Map<String, dynamic> evt) {
    final c = _pending[sessionId.toString()];
    if (c == null || c.isCompleted) return false;
    final msg = (evt['msg'] ?? '').toString();
    if (msg.isNotEmpty) {
      c.completeError('The other computer could not take a picture: $msg');
      return true;
    }
    () async {
      final file = File(
          '${Directory.systemTemp.path}${Platform.pathSeparator}remotless-ai-${DateTime.now().millisecondsSinceEpoch}.png');
      try {
        final res = await bind.sessionHandleScreenshot(
            sessionId: sessionId, action: '0:${file.path}');
        if (res.isNotEmpty) throw res;
        c.complete(await file.readAsBytes());
      } catch (e) {
        if (!c.isCompleted) c.completeError('The picture could not be read: $e');
      } finally {
        try {
          if (await file.exists()) await file.delete();
        } catch (_) {}
      }
    }();
    return true;
  }

  /// At most 1280 px wide: readable for the AI, and a fraction of the size and cost.
  static Future<Uint8List> _shrink(Uint8List png) async {
    final probe = await ui.instantiateImageCodec(png);
    final first = (await probe.getNextFrame()).image;
    final w = first.width;
    first.dispose();
    if (w <= 1280) return png;
    final codec = await ui.instantiateImageCodec(png, targetWidth: 1280);
    final img = (await codec.getNextFrame()).image;
    final data = await img.toByteData(format: ui.ImageByteFormat.png);
    img.dispose();
    return data!.buffer.asUint8List();
  }
}
