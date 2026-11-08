// Remotless: AI in the remote-session window.
//  - A floating "AI assistant" panel (toolbar button): IT questions while connected. The server adds
//    the connected PC's basic facts (Windows version, CPU, memory) so answers fit that PC.
//  - On disconnect, an optional AI summary of the session (with the technician's notes), saved with
//    the session in the dashboard and added to the session report e-mail.
// Only text the technician types is sent, never the screen. Needs the app login (company account);
// the server is our account server: /api/remotless/ai/* (server/src/appapi.js).
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../common.dart';
import '../../models/model.dart';
import '../../models/platform_model.dart';
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
  _Msg(this.role, this.content);
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

  @override
  void initState() {
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
              if (RemotlessAi.loggedIn) _inputRow(theme),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                child: Text(
                  'Only what you type is sent, never the screen. Check commands before you run them.',
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
          const Expanded(
            child: Text('AI assistant',
                style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w600,
                    fontSize: 14)),
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
            : _AnswerText(m.content),
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
