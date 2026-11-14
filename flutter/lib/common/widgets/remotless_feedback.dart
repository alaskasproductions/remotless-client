// Remotless: "Send feedback / Report a problem" from Settings → About (Windows and Android).
// Posts to our server's /api/remotless/feedback (server/src/feedback.js). Works with or without
// a login; when logged in, the app login token tells the server who and which company.
// The recent app log goes along only if the person leaves "Include the app log" ticked.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

import '../../common.dart';
import '../../models/platform_model.dart';
import '../../utils/http_service.dart' as http;

const _kLogBytes = 250 * 1024;

Future<void> showRemotlessFeedback(BuildContext context) async {
  await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const _FeedbackDialog());
}

class _FeedbackDialog extends StatefulWidget {
  const _FeedbackDialog({Key? key}) : super(key: key);

  @override
  State<_FeedbackDialog> createState() => _FeedbackDialogState();
}

class _FeedbackDialogState extends State<_FeedbackDialog> {
  final _message = TextEditingController();
  final _email = TextEditingController();
  String _kind = 'problem';
  bool _includeLog = true;
  bool _sending = false;
  bool _sent = false;
  String _error = '';
  final bool _loggedIn =
      bind.mainGetLocalOption(key: 'access_token').isNotEmpty;

  @override
  void dispose() {
    _message.dispose();
    _email.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final message = _message.text.trim();
    if (message.length < 3) {
      setState(() => _error = 'Please write a few words about it.');
      return;
    }
    final email = _email.text.trim();
    if (email.isNotEmpty && !RegExp(r'^\S+@\S+\.\S+$').hasMatch(email)) {
      setState(() => _error = 'That e-mail address does not look right.');
      return;
    }
    setState(() {
      _sending = true;
      _error = '';
    });
    try {
      final api = await bind.mainGetApiServer();
      if (api.isEmpty) throw 'No Remotless server is set.';
      String device = '';
      try {
        final info = jsonDecode(bind.mainGetLoginDeviceInfo());
        device = '${info['name'] ?? ''}'.trim();
      } catch (_) {}
      final body = <String, dynamic>{
        'kind': _kind,
        'message': message,
        if (!_loggedIn && email.isNotEmpty) 'email': email,
        'id': await bind.mainGetMyId(),
        'uuid': await bind.mainGetUuid(),
        'version': await bind.mainGetVersion(),
        'os': Platform.operatingSystem,
        'osVersion': Platform.operatingSystemVersion,
        'platform': isAndroid ? 'android' : (isDesktop ? 'desktop' : 'other'),
        'device': device,
        'context': {
          'build': await bind.mainGetBuildDate(),
          'language': Platform.localeName,
        },
        'includeLog': _includeLog,
      };
      if (_includeLog) {
        try {
          body['log'] = await bind.mainGetRecentLog(maxBytes: _kLogBytes);
        } catch (_) {}
      }
      final headers = <String, String>{'Content-Type': 'application/json'};
      if (_loggedIn) headers.addAll(getHttpHeaders());
      final resp = await http.post(Uri.parse('$api/api/remotless/feedback'),
          headers: headers, body: jsonEncode(body));
      if (resp.statusCode != 201 && resp.statusCode != 200) {
        String err = 'Sending failed (error ${resp.statusCode}). Try again later, '
            'or e-mail info@remotless.com.';
        try {
          final d = jsonDecode(resp.body);
          if (d is Map && d['error'] != null) err = d['error'].toString();
        } catch (_) {}
        throw err;
      }
      if (mounted) setState(() => _sent = true);
    } catch (e) {
      if (mounted) {
        setState(() => _error = e is String
            ? e
            : 'Could not reach the Remotless server. Check the internet connection and try again.');
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Widget _kindChip(String value, String label) => ChoiceChip(
        label: Text(label),
        selected: _kind == value,
        onSelected: _sending ? null : (_) => setState(() => _kind = value),
      );

  @override
  Widget build(BuildContext context) {
    if (_sent) {
      return AlertDialog(
        title: const Text('Thank you!'),
        content: const Text(
            'We received your message. If we need more details, we will e-mail you.'),
        actions: [
          dialogButton('Close', onPressed: () => Navigator.of(context).pop()),
        ],
      );
    }
    return AlertDialog(
      title: const Text('Send feedback'),
      scrollable: true,
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460, minWidth: 280),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
                'Found a problem or have an idea? Tell us. We read every message.'),
            const SizedBox(height: 12),
            Wrap(spacing: 8, runSpacing: 6, children: [
              _kindChip('problem', 'Something is wrong'),
              _kindChip('idea', 'An idea'),
              _kindChip('other', 'Other'),
            ]),
            const SizedBox(height: 12),
            TextField(
              controller: _message,
              enabled: !_sending,
              minLines: 4,
              maxLines: 8,
              maxLength: 5000,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                hintText:
                    'What happened, or what would you like? For a problem: what did you do, and what did you expect?',
              ),
            ),
            if (!_loggedIn) ...[
              const SizedBox(height: 8),
              TextField(
                controller: _email,
                enabled: !_sending,
                keyboardType: TextInputType.emailAddress,
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  labelText: 'Your e-mail (optional, so we can answer)',
                ),
              ),
            ],
            const SizedBox(height: 4),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              value: _includeLog,
              onChanged: _sending
                  ? null
                  : (v) => setState(() => _includeLog = v ?? false),
              title: const Text('Include the app log'),
              subtitle: const Text(
                  'Technical notes from the app that help us find the cause. '
                  'No screen images, files or passwords.'),
            ),
            Text(
              'We also send the app version, your system and this device\'s Remotless ID'
              '${_loggedIn ? ', and who you are signed in as' : ''}.',
              style: TextStyle(fontSize: 12, color: Theme.of(context).hintColor),
            ),
            if (_error.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(_error, style: const TextStyle(color: Colors.red)),
            ],
          ],
        ),
      ),
      actions: [
        dialogButton('Cancel',
            isOutline: true,
            onPressed: _sending ? null : () => Navigator.of(context).pop()),
        dialogButton(_sending ? 'Sending…' : 'Send',
            onPressed: _sending ? null : _send),
      ],
    );
  }
}
