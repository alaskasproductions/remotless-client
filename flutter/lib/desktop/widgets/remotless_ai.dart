// Remotless: AI in the remote-session window.
//  - A floating "AI assistant" panel (toolbar button): IT questions while connected. The server adds
//    the connected PC's basic facts (Windows version, CPU, memory) so answers fit that PC.
//  - On disconnect, an optional AI summary of the session (with the technician's notes), saved with
//    the session in the dashboard and added to the session report e-mail.
// Only text the technician types is sent; a screen picture only via "Ask about this screen",
// one at a time, after the technician confirms the person agreed (they also get a chat note). Needs the app login (company account);
// the server is our account server: /api/remotless/ai/* (server/src/appapi.js).
import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../common.dart';
import '../../models/model.dart';
import '../../models/platform_model.dart';
import '../../models/remotless_screenshot.dart';
import '../../models/remotless_actions.dart';
import '../../utils/http_service.dart' as http;

const _aiColor = Color(0xff6d4bd8);
const kOptionRemotlessAiSummaryAsk = 'remotless-ai-summary-ask';

class RemotlessAi {
  static bool get loggedIn =>
      bind.mainGetLocalOption(key: 'access_token').isNotEmpty;

  static Map<String, dynamic>? _features;
  static DateTime? _featuresAt;

  /// Which AI features the server offers to this login ({} when logged out or offline).
  static Future<Map<String, dynamic>> features() async {
    if (!loggedIn) return {};
    final at = _featuresAt;
    if (_features != null &&
        at != null &&
        DateTime.now().difference(at) < const Duration(minutes: 5)) {
      return _features!;
    }
    try {
      final api = await bind.mainGetApiServer();
      if (api.isEmpty) return {};
      final resp = await http.get(Uri.parse('$api/api/remotless/ai'),
          headers: getHttpHeaders());
      if (resp.statusCode != 200) return {};
      final data = jsonDecode(resp.body);
      if (data is! Map<String, dynamic>) return {};
      _features = data;
      _featuresAt = DateTime.now();
      return data;
    } catch (_) {
      return {};
    }
  }

  /// AI requests the company has used and has left this month: {used, limit, left (null = unlimited)}.
  static Future<Map<String, dynamic>?> credits() async {
    if (!loggedIn) return null;
    try {
      final api = await bind.mainGetApiServer();
      if (api.isEmpty) return null;
      final resp = await http.get(Uri.parse('$api/api/remotless/ai/credits'), headers: getHttpHeaders());
      if (resp.statusCode != 200) return null;
      final data = jsonDecode(resp.body);
      return data is Map<String, dynamic> ? data : null;
    } catch (_) {
      return null;
    }
  }

  static Future<bool> isOn(String feature) async =>
      (await features())[feature] == true;

  /// POST to /api/remotless/ai/<path>. Throws a readable message on failure.
  static Future<Map<String, dynamic>> post(
      String path, Map<String, dynamic> body) async {
    final api = await bind.mainGetApiServer();
    if (api.isEmpty) throw 'No Remotless server set';
    final headers = getHttpHeaders();
    headers['Content-Type'] = 'application/json';
    final resp = await http.post(Uri.parse('$api/api/remotless/ai/$path'),
        headers: headers, body: jsonEncode(body));
    dynamic data;
    try {
      data = jsonDecode(resp.body);
    } catch (_) {}
    if (resp.statusCode != 200 || data is! Map<String, dynamic>) {
      if (resp.statusCode == 401) {
        throw 'Your login has expired. Log in again in the main window.';
      }
      if (data is Map && data['error'] != null) throw data['error'].toString();
      throw 'The AI did not answer (error ${resp.statusCode}). Try again.';
    }
    return data;
  }
}

// ---------------------------------------------------------------------------
// Toolbar button
// ---------------------------------------------------------------------------

/// Always shown in the session toolbar so technicians can find it; when the app is not logged in,
/// the panel explains how to log in. Hidden only when the logged-in company has it switched off.
class RemotlessAiButton extends StatefulWidget {
  final FFI ffi;
  final String peerId;
  final Widget Function(VoidCallback onPressed) builder;
  const RemotlessAiButton(
      {Key? key,
      required this.ffi,
      required this.peerId,
      required this.builder})
      : super(key: key);

  @override
  State<RemotlessAiButton> createState() => _RemotlessAiButtonState();
}

class _RemotlessAiButtonState extends State<RemotlessAiButton> {
  bool _on = true;

  @override
  void initState() {
    super.initState();
    if (RemotlessAi.loggedIn) {
      // Only an explicit "off" from the server hides it (offline or errors keep it visible).
      RemotlessAi.features().then((f) {
        if (mounted && f['assistant'] == false) setState(() => _on = false);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_on) return const Offstage();
    return widget.builder(
        () => RemotlessAiPanel.toggle(widget.ffi, widget.peerId));
  }
}

// ---------------------------------------------------------------------------
// Floating panel
// ---------------------------------------------------------------------------

class _Msg {
  final String role; // 'user' | 'assistant'
  final String content;
  // "Ask about this screen": the picture that was sent and where the AI says to click (0..1).
  final Uint8List? image;
  final Offset? point;
  final String? pointLabel;
  _Msg(this.role, this.content, {this.image, this.point, this.pointLabel});
  // Follow-up questions carry the text only; the picture is sent once.
  Map<String, String> toJson() => {'role': role, 'content': content};
}

class RemotlessAiPanel {
  static final Map<String, OverlayEntry> _entries = {};
  // The conversation is kept while the session window is open, also when the panel is closed.
  static final Map<String, List<_Msg>> _history = {};
  static final Map<String, Offset> _positions = {};

  static String _key(FFI ffi) => ffi.sessionId.toString();

  static bool isOpen(FFI ffi) => _entries.containsKey(_key(ffi));

  static void toggle(FFI ffi, String peerId) {
    if (isOpen(ffi)) {
      close(ffi);
      return;
    }
    final overlay = ffi.chatModel.blockableOverlayState;
    final state = overlay.state;
    if (state == null) return;
    final key = _key(ffi);
    final entry = OverlayEntry(
        builder: (_) => _AiPanel(
              ffi: ffi,
              peerId: peerId,
              history: _history.putIfAbsent(key, () => []),
              initialPosition: _positions[key],
              onMoved: (p) => _positions[key] = p,
              onClose: () => close(ffi),
            ));
    state.insert(entry);
    _entries[key] = entry;
    // Keys typed in the panel must not reach the remote PC (same as the chat window).
    overlay.setMiddleBlocked(true);
  }

  static void close(FFI ffi) {
    _entries.remove(_key(ffi))?.remove();
    ffi.chatModel.blockableOverlayState.setMiddleBlocked(false);
  }

  /// When the session ends for good.
  static void dispose(FFI ffi) {
    close(ffi);
    _history.remove(_key(ffi));
    _positions.remove(_key(ffi));
  }
}

class _AiPanel extends StatefulWidget {
  final FFI ffi;
  final String peerId;
  final List<_Msg> history;
  final Offset? initialPosition;
  final ValueChanged<Offset> onMoved;
  final VoidCallback onClose;
  const _AiPanel(
      {required this.ffi,
      required this.peerId,
      required this.history,
      required this.initialPosition,
      required this.onMoved,
      required this.onClose});

  @override
  State<_AiPanel> createState() => _AiPanelState();
}

class _AiPanelState extends State<_AiPanel> {
  static const double _w = 380, _h = 500;
  Offset? _pos;
  final _input = TextEditingController();
  final _focus = FocusNode();
  final _scroll = ScrollController();
  bool _busy = false;
  String? _error;
  bool _screenOn = false; // the company has "Ask about this screen" switched on
  bool _askingScreen = false; // the consent box is open
  bool _agreed = false;

  // "Let AI do it": the AI operates the remote PC step by step.
  bool _actOn = false; // switched on for the company (needs Anthropic)
  bool _actAsking = false; // consent box open
  bool _actAgreed = false;
  bool _actAskEach = true; // approve every step (default)
  bool _actRunning = false;
  bool _actStopped = false;
  List<Map<String, dynamic>> _actNext = []; // actions waiting for approval
  Completer<bool>? _actApproval;
  int _actStep = 0;
  String? _credits; // "113 of 150 AI requests left this month"
  bool _creditsLow = false;

  @override
  void initState() {
    RemotlessAi.isOn('screen').then((v) {
      if (mounted && v) setState(() => _screenOn = true);
    });
    _loadCredits();
    RemotlessAi.isOn('act').then((v) {
      if (mounted && v) setState(() => _actOn = true);
    });
    super.initState();
    _pos = widget.initialPosition;
    WidgetsBinding.instance.addPostFrameCallback((_) => _focus.requestFocus());
  }

  @override
  void dispose() {
    _input.dispose();
    _focus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Offset _clamp(Offset p, Size screen) => Offset(
        math.max(0.0, math.min(p.dx, screen.width - _w)),
        math.max(0.0, math.min(p.dy, screen.height - 60)),
      );

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty || _busy) return;
    setState(() {
      widget.history.add(_Msg('user', text));
      _input.clear();
      _busy = true;
      _error = null;
    });
    _toBottom();
    try {
      final msgs = widget.history.length > 12
          ? widget.history.sublist(widget.history.length - 12)
          : widget.history;
      final r = await RemotlessAi.post('assistant', {
        'peer_id': widget.peerId,
        'messages': msgs.map((m) => m.toJson()).toList(),
      });
      widget.history.add(_Msg('assistant', (r['answer'] ?? '').toString()));
      _loadCredits();
    } catch (e) {
      // Take the question back so it can be sent again.
      if (widget.history.isNotEmpty && widget.history.last.role == 'user') {
        _input.text = widget.history.removeLast().content;
      }
      _error = e.toString();
    }
    if (!mounted) return;
    setState(() => _busy = false);
    _toBottom();
    _focus.requestFocus();
  }

  /// One picture of the remote screen + the question in the box, after the person agreed.
  Future<void> _sendScreen() async {
    if (_busy || !_agreed) return;
    final question = _input.text.trim();
    setState(() {
      _askingScreen = false;
      _busy = true;
      _error = null;
    });
    try {
      final png = await RemotlessScreenshot.take(widget.ffi);
      final shown = question.isEmpty
          ? '📷 What is on this screen, and what should I do next?'
          : '📷 $question';
      setState(() {
        widget.history.add(_Msg('user', shown, image: png));
        _input.clear();
      });
      _toBottom();
      final r = await RemotlessAi.post('screen', {
        'peer_id': widget.peerId,
        'consent': true,
        'question': question,
        'image': {'mime': 'image/png', 'data': base64Encode(png)},
      });
      // Tell the person on the other side, in their chat window, that a picture was sent.
      bind.sessionSendChat(
          sessionId: widget.ffi.sessionId,
          text:
              'Your technician sent one picture of your screen to the Remotless AI assistant to help solve the problem.');
      final c = r['click'];
      Offset? point;
      if (c is Map && c['x'] is num && c['y'] is num) {
        point = Offset((c['x'] as num).toDouble(), (c['y'] as num).toDouble());
      }
      _loadCredits();
      widget.history.add(_Msg('assistant', (r['answer'] ?? '').toString(),
          image: point != null ? png : null,
          point: point,
          pointLabel: c is Map ? c['label']?.toString() : null));
    } catch (e) {
      if (widget.history.isNotEmpty &&
          widget.history.last.role == 'user' &&
          widget.history.last.image != null) {
        widget.history.removeLast();
        _input.text = question;
      }
      _error = e.toString();
    }
    _agreed = false;
    if (!mounted) return;
    setState(() => _busy = false);
    _toBottom();
  }

  Future<void> _loadCredits() async {
    final c = await RemotlessAi.credits();
    if (!mounted || c == null) return;
    final limit = (c['limit'] as num?)?.toInt() ?? -1;
    final used = (c['used'] as num?)?.toInt() ?? 0;
    final left = c['left'] == null ? null : (c['left'] as num).toInt();
    setState(() {
      _credits = limit == 0
          ? 'AI is not part of your package'
          : left == null
              ? '$used AI requests used this month (unlimited)'
              : '$left of $limit AI requests left this month';
      _creditsLow = left != null && left <= (limit * 0.1).clamp(5, 1000000);
    });
  }

  void _toBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(_scroll.position.maxScrollExtent,
            duration: const Duration(milliseconds: 200), curve: Curves.easeOut);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final screen = MediaQuery.of(context).size;
    final pos = _clamp(_pos ?? Offset(screen.width - _w - 16, 56), screen);
    final theme = Theme.of(context);
    return Positioned(
      left: pos.dx,
      top: pos.dy,
      child: Listener(
        // Clicking the panel takes the keyboard back from the remote PC.
        onPointerDown: (_) =>
            widget.ffi.chatModel.blockableOverlayState.setMiddleBlocked(true),
        child: Material(
          elevation: 12,
          borderRadius: BorderRadius.circular(10),
          color: theme.cardColor,
          child: SizedBox(
            width: _w,
            height: math.max(200.0, math.min(_h, screen.height - pos.dy - 8)),
            child: Column(children: [
              _header(pos),
              Expanded(
                  child: RemotlessAi.loggedIn
                      ? _messages(theme)
                      : _notLoggedIn(theme)),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
                  child: Text(_error!,
                      style: const TextStyle(color: Colors.red, fontSize: 12)),
                ),
              if (RemotlessAi.loggedIn && _askingScreen) _consentBox(theme),
              if (RemotlessAi.loggedIn && _actAsking) _actConsentBox(theme),
              if (_actRunning) _actControls(theme),
              if (RemotlessAi.loggedIn && !_actRunning) _inputRow(theme),
              if (RemotlessAi.loggedIn && (_screenOn || _actOn) && !_askingScreen && !_actAsking && !_actRunning)
                Padding(
                  padding: const EdgeInsets.only(left: 6),
                  child: Wrap(children: [
                    if (_screenOn)
                      TextButton.icon(
                        onPressed: _busy
                            ? null
                            : () => setState(() {
                                  _askingScreen = true;
                                  _agreed = false;
                                  _error = null;
                                }),
                        icon: const Icon(Icons.photo_camera_outlined, size: 16, color: _aiColor),
                        label: const Text('Ask about this screen',
                            style: TextStyle(color: _aiColor, fontSize: 12)),
                      ),
                    if (_actOn)
                      TextButton.icon(
                        onPressed: _busy
                            ? null
                            : () => setState(() {
                                  _actAsking = true;
                                  _actAgreed = false;
                                  _error = null;
                                }),
                        icon: const Icon(Icons.mouse_outlined, size: 16, color: _aiColor),
                        label: const Text('Let AI do it',
                            style: TextStyle(color: _aiColor, fontSize: 12)),
                      ),
                  ]),
                ),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                child: Text(
                  _screenOn
                      ? 'Only what you type is sent, and a screen picture only when you choose and the person agrees. Check commands before you run them.'
                      : 'Only what you type is sent, never the screen. Check commands before you run them.',
                  style: TextStyle(
                      fontSize: 11, color: theme.hintColor, height: 1.3),
                ),
              ),
            ]),
          ),
        ),
      ),
    );
  }

  Widget _header(Offset pos) {
    return GestureDetector(
      onPanUpdate: (d) {
        setState(() => _pos = pos + d.delta);
        widget.onMoved(_pos!);
      },
      child: Container(
        height: 40,
        padding: const EdgeInsets.only(left: 12, right: 4),
        decoration: const BoxDecoration(
          color: _aiColor,
          borderRadius: BorderRadius.vertical(top: Radius.circular(10)),
        ),
        child: Row(children: [
          const Icon(Icons.auto_awesome, color: Colors.white, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('AI assistant',
                  style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 14)),
              if (_credits != null)
                Text(_credits!,
                    style: TextStyle(
                        color: _creditsLow ? const Color(0xffffd0d0) : Colors.white70, fontSize: 10.5)),
            ]),
          ),
          if (widget.history.isNotEmpty)
            TextButton(
              onPressed: _busy
                  ? null
                  : () => setState(() {
                        widget.history.clear();
                        _error = null;
                      }),
              child: const Text('New conversation',
                  style: TextStyle(color: Colors.white, fontSize: 12)),
            ),
          IconButton(
            tooltip: 'Close',
            icon: const Icon(Icons.close, color: Colors.white, size: 18),
            onPressed: widget.onClose,
          ),
        ]),
      ),
    );
  }

  // ---------------- "Let AI do it" ----------------

  static Future<Size> _sizeOf(Uint8List png) async {
    final codec = await ui.instantiateImageCodec(png);
    final img = (await codec.getNextFrame()).image;
    final s = Size(img.width.toDouble(), img.height.toDouble());
    img.dispose();
    return s;
  }

  static String _describe(Map<String, dynamic> a) {
    final i = (a['input'] is Map) ? Map<String, dynamic>.from(a['input']) : <String, dynamic>{};
    switch (a['name']) {
      case 'left_click':
        return 'Click';
      case 'double_click':
        return 'Double-click';
      case 'triple_click':
        return 'Triple-click';
      case 'right_click':
        return 'Right-click';
      case 'middle_click':
        return 'Middle-click';
      case 'left_click_drag':
        return 'Drag';
      case 'mouse_move':
        return 'Move the mouse';
      case 'type':
        final t = (i['text'] ?? '').toString();
        return 'Type "${t.length > 60 ? '${t.substring(0, 60)}…' : t}"';
      case 'key':
        return 'Press ${i['text']}${(i['repeat'] ?? 1) != 1 ? ' ×${i['repeat']}' : ''}';
      case 'scroll':
        return 'Scroll ${i['scroll_direction'] ?? 'down'}';
      case 'wait':
        return 'Wait ${i['duration'] ?? 1} s';
      case 'screenshot':
        return 'Look at the screen';
      default:
        return a['name'].toString();
    }
  }

  void _chatToCustomer(String text) {
    try {
      bind.sessionSendChat(sessionId: widget.ffi.sessionId, text: text);
    } catch (_) {}
  }

  Future<void> _startAct() async {
    final task = _input.text.trim();
    if (task.length < 3) {
      setState(() => _error = 'Type in the box what the AI should do, e.g. "Open the printer settings and print a test page".');
      return;
    }
    if (!widget.ffi.inputModel.keyboardPerm) {
      setState(() => _error = 'The other computer does not allow mouse and keyboard control in this session.');
      return;
    }
    setState(() {
      _actAsking = false;
      _actRunning = true;
      _actStopped = false;
      _actStep = 0;
      _actNext = [];
      _error = null;
      widget.history.add(_Msg('user', '🖱 $task'));
      _input.clear();
    });
    _toBottom();
    _chatToCustomer('Your technician started the Remotless AI assistant. It may move the mouse and type on your computer while your technician watches. Tell your technician if you want it to stop.');
    String? runId;
    try {
      var png = await RemotlessScreenshot.take(widget.ffi);
      var size = await _sizeOf(png);
      var r = await RemotlessAi.post('act/start', {
        'peer_id': widget.peerId,
        'consent': true,
        'task': task,
        'image': {'mime': 'image/png', 'data': base64Encode(png)},
      });
      runId = r['runId']?.toString();
      while (mounted && !_actStopped) {
        final actions = (r['actions'] is List)
            ? (r['actions'] as List).whereType<Map>().map((m) => Map<String, dynamic>.from(m)).toList()
            : <Map<String, dynamic>>[];
        final note = (r['note'] ?? '').toString();
        _actStep++;
        if (r['done'] == true || actions.isEmpty) {
          setState(() => widget.history.add(_Msg('assistant', note.isEmpty ? 'Done.' : note)));
          break;
        }
        final steps = actions.map((a) => '• ${_describe(a)}').join('\n');
        Offset? point;
        final first = actions.first['input'];
        if (first is Map && first['coordinate'] is List && size.width > 0) {
          final c = first['coordinate'] as List;
          point = Offset((c[0] as num).toDouble() / size.width, (c[1] as num).toDouble() / size.height);
        }
        setState(() {
          widget.history.add(_Msg('assistant', '${note.isEmpty ? 'Next step:' : note}\n$steps',
              image: point != null ? png : null, point: point));
          _actNext = actions;
        });
        _toBottom();
        if (_actAskEach) {
          _actApproval = Completer<bool>();
          setState(() {}); // show the Do it button
          final go = await _actApproval!.future;
          _actApproval = null;
          if (!go || _actStopped) break;
        } else {
          await Future.delayed(const Duration(milliseconds: 1200)); // a moment to press Stop
          if (_actStopped) break;
        }
        setState(() => _actNext = []);
        final results = <Map<String, dynamic>>[];
        for (final a in actions) {
          if (_actStopped) break;
          try {
            await RemotlessActions.perform(widget.ffi, a['name'].toString(),
                (a['input'] is Map) ? Map<String, dynamic>.from(a['input']) : {}, size);
            results.add({'id': a['id'], 'ok': true});
          } catch (e) {
            results.add({'id': a['id'], 'ok': false, 'error': e.toString()});
            break;
          }
        }
        if (_actStopped) break;
        await Future.delayed(const Duration(milliseconds: 900)); // let the screen update
        png = await RemotlessScreenshot.take(widget.ffi);
        size = await _sizeOf(png);
        r = await RemotlessAi.post('act/step', {
          'runId': runId,
          'results': results,
          'image': {'mime': 'image/png', 'data': base64Encode(png)},
        });
      }
      if (_actStopped && mounted) {
        setState(() => widget.history.add(_Msg('assistant', 'Stopped. Nothing more will be done.')));
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (runId != null) {
        RemotlessAi.post('act/stop', {'runId': runId}).catchError((_) => <String, dynamic>{});
      }
      _chatToCustomer('The Remotless AI assistant has stopped.');
      _loadCredits();
      if (mounted) {
        setState(() {
          _actRunning = false;
          _actNext = [];
        });
        _toBottom();
      }
    }
  }

  void _stopAct() {
    _actStopped = true;
    final c = _actApproval;
    if (c != null && !c.isCompleted) c.complete(false);
    setState(() {});
  }

  /// Asked every time before the AI may operate the other computer.
  Widget _actConsentBox(ThemeData theme) => Container(
        margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: _aiColor.withOpacity(0.08),
          border: Border.all(color: _aiColor.withOpacity(0.4)),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Let the AI use the mouse and keyboard on the other computer?',
              style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
          const SizedBox(height: 4),
          Text(
              'Type the task in the box below first. The AI sees the screen, decides the next clicks and keys, and you watch. '
              'It never types passwords or makes payments, and stops when something unexpected appears. The person gets a note in their chat.',
              style: TextStyle(fontSize: 12, color: theme.hintColor, height: 1.35)),
          Row(children: [
            Checkbox(
                value: _actAgreed,
                activeColor: _aiColor,
                onChanged: (v) => setState(() => _actAgreed = v ?? false)),
            const Expanded(child: Text('The person I am helping agreed', style: TextStyle(fontSize: 12))),
          ]),
          Row(children: [
            Checkbox(
                value: _actAskEach,
                activeColor: _aiColor,
                onChanged: (v) => setState(() => _actAskEach = v ?? true)),
            const Expanded(child: Text('Ask me before each step (recommended)', style: TextStyle(fontSize: 12))),
          ]),
          Row(mainAxisAlignment: MainAxisAlignment.end, children: [
            TextButton(onPressed: () => setState(() => _actAsking = false), child: const Text('Cancel')),
            const SizedBox(width: 6),
            ElevatedButton.icon(
              style: ElevatedButton.styleFrom(backgroundColor: _aiColor, foregroundColor: Colors.white),
              onPressed: _actAgreed ? _startAct : null,
              icon: const Icon(Icons.mouse_outlined, size: 16),
              label: const Text('Start'),
            ),
          ]),
        ]),
      );

  /// While the AI is working: approve the next step, or stop.
  Widget _actControls(ThemeData theme) => Container(
        margin: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: Colors.red.withOpacity(0.06),
          border: Border.all(color: Colors.red.withOpacity(0.35)),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(children: [
          Expanded(
            child: Text(
              _actNext.isNotEmpty && _actAskEach
                  ? 'Step $_actStep: check the plan above, then click Do it.'
                  : 'The AI is working (step $_actStep)…',
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
            ),
          ),
          if (_actNext.isNotEmpty && _actAskEach && _actApproval != null) ...[
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: _aiColor, foregroundColor: Colors.white),
              onPressed: () {
                final c = _actApproval;
                if (c != null && !c.isCompleted) c.complete(true);
              },
              child: const Text('Do it'),
            ),
            const SizedBox(width: 6),
          ],
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red, foregroundColor: Colors.white),
            onPressed: _stopAct,
            icon: const Icon(Icons.stop, size: 16),
            label: const Text('Stop'),
          ),
        ]),
      );

  /// Asked every time before a picture of the remote screen is sent.
  Widget _consentBox(ThemeData theme) => Container(
        margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: _aiColor.withOpacity(0.08),
          border: Border.all(color: _aiColor.withOpacity(0.4)),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Send one picture of the other computer\'s screen to the AI?',
              style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
          const SizedBox(height: 4),
          Text(
              'The AI sees everything on that screen. Close emails, banking or private documents first. '
              'Your question is the text in the box below (or leave it empty). The person will see a note in their chat.',
              style: TextStyle(fontSize: 12, color: theme.hintColor, height: 1.35)),
          Row(children: [
            Checkbox(
                value: _agreed,
                activeColor: _aiColor,
                onChanged: (v) => setState(() => _agreed = v ?? false)),
            const Expanded(
                child: Text('The person I am helping agreed',
                    style: TextStyle(fontSize: 12))),
          ]),
          Row(mainAxisAlignment: MainAxisAlignment.end, children: [
            TextButton(
                onPressed: () => setState(() => _askingScreen = false),
                child: const Text('Cancel')),
            const SizedBox(width: 6),
            ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                  backgroundColor: _aiColor, foregroundColor: Colors.white),
              onPressed: _agreed ? _sendScreen : null,
              icon: const Icon(Icons.photo_camera_outlined, size: 16),
              label: const Text('Send picture'),
            ),
          ]),
        ]),
      );

  /// The picture the AI looked at, with a red ring where it says to click.
  Widget _pictureWithPoint(_Msg m) => Padding(
        padding: const EdgeInsets.only(top: 6),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: LayoutBuilder(builder: (context, c) {
            return Stack(children: [
              Image.memory(m.image!, width: c.maxWidth, fit: BoxFit.fitWidth),
              if (m.point != null)
                Positioned.fill(
                  child: LayoutBuilder(builder: (context, box) {
                    const r = 11.0;
                    return Stack(children: [
                      Positioned(
                        left: m.point!.dx * box.maxWidth - r,
                        top: m.point!.dy * box.maxHeight - r,
                        child: Container(
                          width: r * 2,
                          height: r * 2,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            border: Border.all(color: Colors.red, width: 3),
                            color: Colors.red.withOpacity(0.15),
                          ),
                        ),
                      ),
                    ]);
                  }),
                ),
            ]);
          }),
        ),
      );

  Widget _notLoggedIn(ThemeData theme) => Padding(
        padding: const EdgeInsets.all(16),
        child: Text(
          'Log in to your Remotless company account in the main window (Settings → Account → Login) to use the AI assistant.',
          style: TextStyle(color: theme.hintColor, height: 1.4),
        ),
      );

  Widget _messages(ThemeData theme) {
    if (widget.history.isEmpty && !_busy) {
      return Padding(
        padding: const EdgeInsets.all(16),
        child: Text(
          'Ask anything about the problem you are fixing, for example:\n\n'
          '• "Printer shows error 0x00000709, how do I fix it?"\n'
          '• "PowerShell command to clear the Windows Update cache"\n'
          '• "Outlook keeps asking for the password"\n\n'
          'The assistant knows this PC\'s Windows version.',
          style: TextStyle(color: theme.hintColor, height: 1.4, fontSize: 13),
        ),
      );
    }
    return ListView(
      controller: _scroll,
      padding: const EdgeInsets.all(12),
      children: [
        for (final m in widget.history) _bubble(m, theme),
        if (_busy)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(children: [
              const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2)),
              const SizedBox(width: 8),
              Text('Thinking…', style: TextStyle(color: theme.hintColor)),
            ]),
          ),
      ],
    );
  }

  Widget _bubble(_Msg m, ThemeData theme) {
    final mine = m.role == 'user';
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        constraints: const BoxConstraints(maxWidth: _w - 40),
        decoration: BoxDecoration(
          color: mine
              ? _aiColor.withOpacity(0.12)
              : theme.dividerColor.withOpacity(0.12),
          borderRadius: BorderRadius.circular(8),
        ),
        child: mine
            ? SelectableText(m.content, style: const TextStyle(fontSize: 13))
            : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                _AnswerText(m.content),
                if (m.image != null && m.point != null) ...[
                  _pictureWithPoint(m),
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                        '🔴 Click here${(m.pointLabel ?? '').isNotEmpty ? ': ${m.pointLabel}' : ''}',
                        style: const TextStyle(
                            fontSize: 12, fontWeight: FontWeight.w600)),
                  ),
                ],
              ]),
      ),
    );
  }

  Widget _inputRow(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
      child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
        Expanded(
          child: Focus(
            onKeyEvent: (node, e) {
              // Enter sends; Shift+Enter makes a new line.
              if (e is KeyDownEvent &&
                  (e.logicalKey == LogicalKeyboardKey.enter ||
                      e.logicalKey == LogicalKeyboardKey.numpadEnter) &&
                  !HardwareKeyboard.instance.isShiftPressed) {
                _send();
                return KeyEventResult.handled;
              }
              return KeyEventResult.ignored;
            },
            child: TextField(
              controller: _input,
              focusNode: _focus,
              minLines: 1,
              maxLines: 4,
              maxLength: 4000,
              style: const TextStyle(fontSize: 13),
              decoration: const InputDecoration(
                hintText: 'Type your question…',
                counterText: '',
                isDense: true,
                border: OutlineInputBorder(),
                contentPadding:
                    EdgeInsets.symmetric(horizontal: 10, vertical: 10),
              ),
            ),
          ),
        ),
        const SizedBox(width: 8),
        ElevatedButton(
          style: ElevatedButton.styleFrom(
              backgroundColor: _aiColor, foregroundColor: Colors.white),
          onPressed: _busy ? null : _send,
          child: const Text('Ask'),
        ),
      ]),
    );
  }
}

/// An answer: plain text with ``` code blocks shown in monospace with a Copy button.
class _AnswerText extends StatelessWidget {
  final String text;
  const _AnswerText(this.text);

  @override
  Widget build(BuildContext context) {
    final parts = text.split('```');
    final children = <Widget>[];
    for (var i = 0; i < parts.length; i++) {
      var p = parts[i];
      if (i.isOdd) {
        // Drop the language name on the first line ("```powershell").
        final nl = p.indexOf('\n');
        if (nl >= 0 && !p.substring(0, nl).contains(' ')) p = p.substring(nl + 1);
        p = p.trimRight();
        if (p.isEmpty) continue;
        children.add(_code(context, p));
      } else {
        final t = p.replaceAll('**', '').trim();
        if (t.isEmpty) continue;
        children.add(Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: SelectableText(t,
              style: const TextStyle(fontSize: 13, height: 1.4)),
        ));
      }
    }
    return Column(
        crossAxisAlignment: CrossAxisAlignment.start, children: children);
  }

  Widget _code(BuildContext context, String code) => Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.fromLTRB(8, 6, 4, 6),
        decoration: BoxDecoration(
          color: const Color(0xff1e1e2e),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(
            child: SelectableText(code,
                style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 12,
                    color: Color(0xffe6e6f0),
                    height: 1.35)),
          ),
          IconButton(
            tooltip: 'Copy',
            visualDensity: VisualDensity.compact,
            iconSize: 16,
            icon: const Icon(Icons.copy, color: Color(0xffe6e6f0)),
            onPressed: () {
              Clipboard.setData(ClipboardData(text: code));
              showToast('Copied');
            },
          ),
        ]),
      );
}

// ---------------------------------------------------------------------------
// AI summary when the technician disconnects
// ---------------------------------------------------------------------------

/// Asked before the session window closes the connection. Returns false if the technician
/// pressed Cancel (stay connected). Never blocks closing when AI is off or not logged in.
Future<bool> remotlessAskSummaryBeforeClose(FFI ffi, String peerId) async {
  if (bind.mainGetLocalOption(key: kOptionRemotlessAiSummaryAsk) == 'N') {
    return true;
  }
  if (!await RemotlessAi.isOn('summary')) return true;
  final notes = TextEditingController();
  var dontAsk = false;
  var sending = false;
  String? error;
  final overlay = ffi.chatModel.blockableOverlayState;
  final result = await ffi.dialogManager.show<bool>((setState, close, context) {
    Future<void> write() async {
      setState(() {
        sending = true;
        error = null;
      });
      try {
        await RemotlessAi.post(
            'summary', {'peer_id': peerId, 'notes': notes.text.trim()});
        close(true);
      } catch (e) {
        setState(() {
          sending = false;
          error = e.toString();
        });
      }
    }

    void skip() {
      if (dontAsk) {
        bind.mainSetLocalOption(key: kOptionRemotlessAiSummaryAsk, value: 'N');
      }
      close(true);
    }

    return CustomAlertDialog(
      title: Row(children: const [
        Icon(Icons.auto_awesome, color: _aiColor),
        SizedBox(width: 8),
        Text('Write an AI summary?'),
      ]),
      content: SizedBox(
        width: 420,
        child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                  'The AI writes a short summary of this session from its facts and your notes. '
                  'It is saved with the session in your dashboard and added to the session report e-mail.',
                  style: TextStyle(height: 1.4)),
              const SizedBox(height: 12),
              TextField(
                controller: notes,
                autofocus: true,
                minLines: 2,
                maxLines: 5,
                maxLength: 2000,
                decoration: const InputDecoration(
                  labelText: 'What did you do? (optional)',
                  hintText: 'e.g. Reinstalled the printer driver, test page OK',
                  border: OutlineInputBorder(),
                ),
              ),
              if (error != null)
                Text(error!, style: const TextStyle(color: Colors.red)),
              Row(children: [
                Checkbox(
                    value: dontAsk,
                    onChanged: sending
                        ? null
                        : (v) => setState(() => dontAsk = v ?? false)),
                const Expanded(
                    child: Text('Don\'t ask again (you can still write summaries in the dashboard)',
                        style: TextStyle(fontSize: 12))),
              ]),
            ]),
      ),
      actions: [
        dialogButton('Cancel',
            onPressed: sending ? null : () => close(false), isOutline: true),
        dialogButton('Close without summary',
            onPressed: sending ? null : skip, isOutline: true),
        dialogButton(sending ? 'Writing…' : 'Write summary and close',
            onPressed: sending ? null : write),
      ],
      onCancel: sending ? null : () => close(false),
    );
  });
  overlay.setMiddleBlocked(false);
  notes.dispose();
  return result != false;
}
