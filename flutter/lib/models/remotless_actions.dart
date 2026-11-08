// Remotless "Let AI do it": performs one computer-use action from the AI on the remote PC.
// The AI gives coordinates in the pixel space of the screenshot we sent (shrunk to <= 1280 px wide);
// they are mapped onto the remote display (its offset and real size) before the mouse moves.
// Action names and inputs follow Anthropic's computer toolset (computer_toolset_20260801).
import 'dart:convert';
import 'dart:ui';

import 'package:flutter_hbb/models/input_model.dart';
import 'package:flutter_hbb/models/model.dart';
import 'package:flutter_hbb/models/platform_model.dart';

class RemotlessActions {
  /// [shot] is the size of the screenshot the AI saw. Throws a short message when an action
  /// can't be done (the AI is told and can try another way).
  static Future<void> perform(FFI ffi, String name, Map<String, dynamic> input, Size shot) async {
    final input0 = ffi.inputModel;
    if (!input0.keyboardPerm) {
      throw 'The other computer does not allow mouse and keyboard control in this session.';
    }
    final pi = ffi.ffiModel.pi;
    final idx = pi.currentDisplay;
    if (idx < 0 || idx >= pi.displays.length) throw 'Show one screen of the other computer first.';
    final d = pi.displays[idx];
    final sx = d.width / shot.width, sy = d.height / shot.height;
    Offset? at(dynamic c) {
      if (c is List && c.length == 2 && c[0] is num && c[1] is num) {
        final x = (c[0] as num).toDouble(), y = (c[1] as num).toDouble();
        if (x < 0 || y < 0 || x > shot.width || y > shot.height) throw 'That point is outside the screen.';
        return Offset(d.x + x * sx, d.y + y * sy);
      }
      return null;
    }

    Future<void> moveTo(Offset p) async {
      await input0.moveMouse(p.dx, p.dy);
      await Future.delayed(const Duration(milliseconds: 60));
    }

    Future<void> click(MouseButtons b, int times) async {
      for (var i = 0; i < times; i++) {
        await input0.tapDown(b);
        await input0.tapUp(b);
        await Future.delayed(const Duration(milliseconds: 70));
      }
    }

    // Modifier keys the AI may hold during a click or scroll ("ctrl", "shift+alt", ...).
    final mods = _mods(input['text']);
    Future<void> withMods(Future<void> Function() f) async {
      for (final m in mods) {
        bind.sessionInputKey(sessionId: ffi.sessionId, name: m, down: true, press: false, alt: false, ctrl: false, shift: false, command: false);
      }
      try {
        await f();
      } finally {
        for (final m in mods.reversed) {
          bind.sessionInputKey(sessionId: ffi.sessionId, name: m, down: false, press: false, alt: false, ctrl: false, shift: false, command: false);
        }
      }
    }

    switch (name) {
      case 'screenshot':
      case 'wait':
        if (name == 'wait') {
          final s = (input['duration'] is num ? (input['duration'] as num).toDouble() : 1.0).clamp(0.2, 10.0);
          await Future.delayed(Duration(milliseconds: (s * 1000).round()));
        }
        return; // a fresh screenshot is taken after every batch anyway
      case 'mouse_move':
        final p = at(input['coordinate']);
        if (p == null) throw 'No position given.';
        await moveTo(p);
        return;
      case 'left_click':
      case 'right_click':
      case 'middle_click':
      case 'double_click':
      case 'triple_click':
        final p = at(input['coordinate']);
        if (p != null) await moveTo(p);
        final b = name == 'right_click' ? MouseButtons.right : name == 'middle_click' ? MouseButtons.wheel : MouseButtons.left;
        final times = name == 'double_click' ? 2 : name == 'triple_click' ? 3 : 1;
        await withMods(() => click(b, times));
        return;
      case 'left_click_drag':
        final from = at(input['start_coordinate']), to = at(input['coordinate']);
        if (from == null || to == null) throw 'Start and end positions are needed.';
        await withMods(() async {
          await moveTo(from);
          await input0.tapDown(MouseButtons.left);
          for (var i = 1; i <= 8; i++) {
            await moveTo(Offset.lerp(from, to, i / 8)!);
          }
          await input0.tapUp(MouseButtons.left);
        });
        return;
      case 'scroll':
        final p = at(input['coordinate']);
        if (p != null) await moveTo(p);
        final amount = (input['scroll_amount'] is num ? (input['scroll_amount'] as num).toInt() : 3).clamp(1, 20);
        final dir = (input['scroll_direction'] ?? 'down').toString();
        await withMods(() async {
          for (var i = 0; i < amount; i++) {
            final x = dir == 'left' ? 1 : dir == 'right' ? -1 : 0;
            final y = dir == 'up' ? 1 : dir == 'down' ? -1 : 0;
            await bind.sessionSendMouse(
                sessionId: ffi.sessionId, msg: jsonEncode({'type': 'wheel', 'x': '$x', 'y': '$y'}));
            await Future.delayed(const Duration(milliseconds: 40));
          }
        });
        return;
      case 'type':
        final t = (input['text'] ?? '').toString();
        if (t.isEmpty) return;
        if (t.length > 2000) throw 'That text is too long to type.';
        await bind.sessionInputString(sessionId: ffi.sessionId, value: t);
        await Future.delayed(const Duration(milliseconds: 120));
        return;
      case 'key':
        final combo = (input['text'] ?? '').toString();
        final repeat = (input['repeat'] is num ? (input['repeat'] as num).toInt() : 1).clamp(1, 50);
        final k = _key(combo);
        if (k == null) throw 'Unknown key: $combo';
        for (var i = 0; i < repeat; i++) {
          bind.sessionInputKey(sessionId: ffi.sessionId, name: k.name, down: false, press: true,
              alt: k.alt, ctrl: k.ctrl, shift: k.shift, command: k.win);
          await Future.delayed(const Duration(milliseconds: 60));
        }
        return;
      default:
        throw 'The action "$name" is not available here.';
    }
  }

  static List<String> _mods(dynamic text) {
    if (text is! String || text.isEmpty) return const [];
    return text.toLowerCase().split('+').map((m) {
      switch (m.trim()) {
        case 'ctrl':
        case 'control':
          return 'VK_CONTROL';
        case 'shift':
          return 'VK_SHIFT';
        case 'alt':
          return 'VK_MENU';
        case 'super':
        case 'win':
        case 'meta':
          return 'Meta';
        default:
          return '';
      }
    }).where((m) => m.isNotEmpty).toList();
  }

  static const Map<String, String> _names = {
    'return': 'VK_RETURN', 'enter': 'VK_RETURN', 'kp_enter': 'VK_RETURN', 'tab': 'VK_TAB', 'escape': 'VK_ESCAPE', 'esc': 'VK_ESCAPE',
    'backspace': 'VK_BACK', 'back_space': 'VK_BACK', 'delete': 'VK_DELETE', 'del': 'VK_DELETE', 'insert': 'VK_INSERT',
    'space': 'VK_SPACE', 'up': 'VK_UP', 'down': 'VK_DOWN', 'left': 'VK_LEFT', 'right': 'VK_RIGHT', 'home': 'VK_HOME', 'end': 'VK_END',
    'page_up': 'VK_PRIOR', 'pageup': 'VK_PRIOR', 'prior': 'VK_PRIOR', 'page_down': 'VK_NEXT', 'pagedown': 'VK_NEXT', 'next': 'VK_NEXT',
    'super': 'Meta', 'super_l': 'Meta', 'win': 'Meta', 'meta': 'Meta', 'menu': 'Apps', 'print': 'VK_SNAPSHOT',
    'minus': 'VK_MINUS', 'plus': 'VK_PLUS', 'comma': 'VK_COMMA', 'slash': 'VK_SLASH', 'semicolon': 'VK_SEMICOLON',
  };

  static ({String name, bool ctrl, bool shift, bool alt, bool win})? _key(String combo) {
    final parts = combo.split('+').map((p) => p.trim()).where((p) => p.isNotEmpty).toList();
    if (parts.isEmpty) return null;
    var ctrl = false, shift = false, alt = false, win = false;
    for (final m in parts.take(parts.length - 1)) {
      switch (m.toLowerCase()) {
        case 'ctrl':
        case 'control':
          ctrl = true;
          break;
        case 'shift':
          shift = true;
          break;
        case 'alt':
          alt = true;
          break;
        case 'super':
        case 'win':
        case 'meta':
        case 'cmd':
          win = true;
          break;
      }
    }
    final last = parts.last;
    final low = last.toLowerCase();
    String? name = _names[low];
    if (name == null && RegExp(r'^f([1-9]|1[0-2])$').hasMatch(low)) name = 'VK_${low.toUpperCase()}';
    if (name == null && RegExp(r'^[a-z0-9]$').hasMatch(low)) name = 'VK_${low.toUpperCase()}';
    if (name == null && last.length == 1) name = last; // other single characters are sent as typed
    if (name == null) return null;
    // A lone Windows key: send it as the key itself, not as a modifier of nothing.
    if (name == 'Meta' && parts.length == 1) win = false;
    return (name: name, ctrl: ctrl, shift: shift, alt: alt, win: win);
  }
}
