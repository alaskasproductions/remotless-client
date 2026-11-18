// Remotless: "Share screen" tab on iPhone/iPad (view only).
//
// The sharing itself runs in the RemotlessBroadcast extension (flutter/ios/RemotlessBroadcast),
// which iOS keeps running while the user is in other apps. This tab writes the ID, one-time
// password and server settings for it, starts the system broadcast sheet, shows who is
// watching, and lets the user accept or deny a technician who has no password.
// Native side: flutter/ios/Runner/RemotlessShareScreen.swift. Design: docs/ios-screen-share.md.

import 'dart:convert';
import 'dart:math';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../common.dart';
import '../../common/formatter/id_formatter.dart';
import '../../common/widgets/remotless_peer_badge.dart';
import '../../models/platform_model.dart';
import 'home_page.dart';

class IosShareClient {
  final int id;
  final String peerId;
  final String name;
  final bool authorized;
  IosShareClient(this.id, this.peerId, this.name, this.authorized);
}

/// App-wide state of iOS screen sharing; lives as long as the app, because the extension can
/// ask for the user's answer while another tab is open.
class IosShareModel extends ChangeNotifier with WidgetsBindingObserver {
  static final IosShareModel instance = IosShareModel._();
  static const _channel = MethodChannel('com.remotless/share_screen');

  IosShareModel._();

  bool _initialized = false;
  bool supported = false;
  bool sharing = false;
  String id = '';
  String password = '';
  String error = '';
  List<IosShareClient> clients = [];

  List<IosShareClient> get pending => clients.where((c) => !c.authorized).toList();
  List<IosShareClient> get watching => clients.where((c) => c.authorized).toList();

  Future<void> init() async {
    if (_initialized || !isIOS) return;
    _initialized = true;
    WidgetsBinding.instance.addObserver(this);
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onState') _applyState(call.arguments as String? ?? '');
    });
    try {
      supported = await _channel.invokeMethod<bool>('isSupported') ?? false;
    } catch (_) {
      supported = false;
    }
    id = await bind.mainGetMyId();
    newPassword(notify: false);
    await writeConfig();
    await refresh();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // A suspended app misses the extension's notifications: read its state again.
    if (state == AppLifecycleState.resumed) refresh();
  }

  /// A new one-time password; the extension takes it at once if it is already sharing.
  void newPassword({bool notify = true}) {
    const chars = 'abcdefghijkmnpqrstuvwxyz23456789';
    final r = Random.secure();
    password = List.generate(8, (_) => chars[r.nextInt(chars.length)]).join();
    if (notify) {
      writeConfig();
      notifyListeners();
    }
  }

  Future<void> writeConfig() async {
    if (!supported) return;
    final options = <String, String>{};
    for (final k in [
      'custom-rendezvous-server',
      'relay-server',
      'api-server',
      'key',
      'allow-websocket'
    ]) {
      final v = await bind.mainGetOption(key: k);
      if (v.isNotEmpty) options[k] = v;
    }
    String deviceName = 'iPhone';
    try {
      final info = await DeviceInfoPlugin().iosInfo;
      if (info.name.isNotEmpty) deviceName = info.name;
    } catch (_) {}
    final config = jsonEncode({
      'id': id,
      'password': password,
      'device_name': deviceName,
      'options': options,
    });
    try {
      await _channel.invokeMethod('writeConfig', config);
    } catch (_) {}
  }

  Future<void> refresh() async {
    if (!supported) return;
    try {
      _applyState(await _channel.invokeMethod<String>('readState') ?? '');
    } catch (_) {}
  }

  void _applyState(String json) {
    final before = pending.map((c) => c.id).toSet();
    if (json.isEmpty) {
      sharing = false;
      clients = [];
    } else {
      try {
        final m = jsonDecode(json) as Map<String, dynamic>;
        // A state file left behind by a broadcast that iOS ended without telling us.
        final updated = (m['updated'] as num?)?.toDouble() ?? 0;
        final age = DateTime.now().millisecondsSinceEpoch / 1000 - updated;
        sharing = m['sharing'] == true && age < 24 * 3600;
        final regId = (m['id'] ?? '').toString();
        if (sharing && regId.isNotEmpty) id = regId;
        error = (m['error'] ?? '').toString();
        clients = sharing
            ? ((m['clients'] as List?) ?? [])
                .whereType<Map>()
                .map((c) => IosShareClient(
                    (c['id'] as num?)?.toInt() ?? 0,
                    (c['peer_id'] ?? '').toString(),
                    (c['name'] ?? '').toString(),
                    c['authorized'] == true))
                .toList()
            : [];
      } catch (_) {
        return;
      }
    }
    // Someone new is waiting for an answer: bring the Share screen tab to the front.
    if (pending.any((c) => !before.contains(c.id))) {
      HomePage.homeKey.currentState?.showIosShareTab();
    }
    notifyListeners();
  }

  Future<void> _command(String cmd, [int id = 0]) async {
    try {
      await _channel.invokeMethod('command', {'cmd': cmd, 'id': id});
    } catch (_) {}
  }

  Future<void> answer(IosShareClient c, bool accept) async {
    await _command(accept ? 'authorize' : 'deny', c.id);
  }

  Future<void> disconnect() => _command('disconnect');

  Future<void> stop() => _command('stop');

  Future<bool> start() async {
    if (!supported) return false;
    await writeConfig();
    try {
      // Lets the extension tell the user about a technician while they are in another app.
      await _channel.invokeMethod('requestNotifications');
    } catch (_) {}
    try {
      return await _channel.invokeMethod<bool>('startBroadcast') ?? false;
    } catch (_) {
      return false;
    }
  }
}

class IosSharePage extends StatefulWidget implements PageShape {
  @override
  final title = translate("Share screen");

  @override
  final icon = const Icon(Icons.mobile_screen_share);

  @override
  final appBarActions = <Widget>[];

  IosSharePage({Key? key}) : super(key: key);

  @override
  State<IosSharePage> createState() => _IosSharePageState();
}

class _IosSharePageState extends State<IosSharePage> {
  final model = IosShareModel.instance;

  @override
  void initState() {
    super.initState();
    model.addListener(_changed);
    model.init().then((_) => _changed());
  }

  @override
  void dispose() {
    model.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final m = model;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        for (final c in m.pending) _requestCard(c),
        _idCard(),
        const SizedBox(height: 12),
        _statusCard(),
        for (final c in m.watching) _watchingCard(c),
        const SizedBox(height: 12),
        _infoText(),
      ],
    );
  }

  Widget _idCard() {
    final m = model;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(translate('ID'), style: const TextStyle(color: Colors.grey)),
            Row(children: [
              Expanded(
                child: SelectableText(formatID(m.id),
                    style: const TextStyle(
                        fontSize: 28, fontWeight: FontWeight.bold)),
              ),
              IconButton(
                icon: const Icon(Icons.copy),
                tooltip: translate('Copy'),
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: m.id));
                  showToast(translate('Copied'));
                },
              ),
            ]),
            const SizedBox(height: 8),
            Text(translate('One-time Password'),
                style: const TextStyle(color: Colors.grey)),
            Row(children: [
              Expanded(
                child: SelectableText(m.password,
                    style: const TextStyle(
                        fontSize: 24, fontWeight: FontWeight.w600)),
              ),
              IconButton(
                icon: const Icon(Icons.refresh),
                tooltip: 'New password',
                onPressed: () => m.newPassword(),
              ),
            ]),
          ],
        ),
      ),
    );
  }

  Widget _statusCard() {
    final m = model;
    if (!m.supported) {
      return const Card(
        child: Padding(
          padding: EdgeInsets.all(16),
          child: Text(
              'Screen sharing is not available in this version of the app.'),
        ),
      );
    }
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(children: [
              Icon(m.sharing ? Icons.cast_connected : Icons.cast,
                  color: m.sharing ? const Color(0xff1f9d5c) : Colors.grey),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  m.sharing
                      ? (m.watching.isEmpty
                          ? 'Ready. Waiting for your technician to connect.'
                          : 'Your screen is being shared.')
                      : 'Your screen is not shared.',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
            ]),
            if (m.error.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(m.error, style: const TextStyle(color: Colors.red)),
              ),
            const SizedBox(height: 12),
            if (!m.sharing)
              ElevatedButton.icon(
                icon: const Icon(Icons.play_arrow),
                label: const Text('Start sharing'),
                style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 14)),
                onPressed: () async {
                  final ok = await m.start();
                  if (!ok && mounted) {
                    showToast(
                        'Open Control Center, press and hold Screen Recording, choose Remotless and tap Start Broadcast.');
                  }
                },
              )
            else ...[
              if (m.watching.isNotEmpty)
                OutlinedButton.icon(
                  icon: const Icon(Icons.person_off),
                  label: const Text('Disconnect technician'),
                  onPressed: () => m.disconnect(),
                ),
              const SizedBox(height: 8),
              ElevatedButton.icon(
                icon: const Icon(Icons.stop),
                label: const Text('Stop sharing'),
                style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xffc0392b),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14)),
                onPressed: () => m.stop(),
              ),
            ],
          ],
        ),
      ),
    );
  }

  String _who(IosShareClient c) =>
      c.name.isNotEmpty ? '${c.name} (${formatID(c.peerId)})' : formatID(c.peerId);

  Widget _requestCard(IosShareClient c) {
    return Card(
      color: const Color(0xfffff4e5),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('Someone wants to see your screen',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            const SizedBox(height: 6),
            Text(_who(c)),
            RemotlessPeerBadge(peerId: c.peerId),
            const SizedBox(height: 8),
            const Text(
                'Only allow this if you asked this person for help. They will see everything on your screen, including messages and codes, until you stop sharing.',
                style: TextStyle(fontSize: 12)),
            const SizedBox(height: 12),
            Row(children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () => model.answer(c, false),
                  child: Text(translate('Dismiss')),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: ElevatedButton(
                  onPressed: () => model.answer(c, true),
                  child: Text(translate('Accept')),
                ),
              ),
            ]),
          ],
        ),
      ),
    );
  }

  Widget _watchingCard(IosShareClient c) {
    return Card(
      child: ListTile(
        leading: const Icon(Icons.visibility, color: Color(0xff1f6feb)),
        title: Text(_who(c)),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Is watching your screen (view only)'),
            RemotlessPeerBadge(peerId: c.peerId),
          ],
        ),
      ),
    );
  }

  Widget _infoText() {
    return const Text(
      'Give your ID and password only to someone you asked for help. '
      'The technician can only see your screen: iOS does not let anyone tap or type on '
      'your iPhone or iPad remotely. Sharing keeps running when you switch apps; stop it '
      'here or with the red indicator at the top of the screen.',
      style: TextStyle(color: Colors.grey, fontSize: 12),
    );
  }
}
