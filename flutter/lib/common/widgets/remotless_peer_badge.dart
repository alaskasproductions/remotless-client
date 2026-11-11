// Remotless scam shield, shared by the Windows accept window and the Android Share screen card.
import 'dart:convert';

import 'package:flutter/material.dart';

import '../../models/platform_model.dart';
import '../../utils/http_service.dart' as http;

/// Remotless scam shield: asks our server whether the Remotless ID that is connecting belongs to a
/// verified company, an unverified one, a blocked account, or nobody we know, and says so clearly
/// in the accept window. Shows nothing if the server can't be reached.
class RemotlessPeerBadge extends StatefulWidget {
  final String peerId;
  const RemotlessPeerBadge({Key? key, required this.peerId}) : super(key: key);
  @override
  State<RemotlessPeerBadge> createState() => RemotlessPeerBadgeState();
}

class RemotlessPeerBadgeState extends State<RemotlessPeerBadge> {
  Map<String, dynamic>? _info;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final api = await bind.mainGetApiServer();
      if (api.isEmpty) return;
      final resp = await http.get(Uri.parse('$api/api/peer-check?id=${Uri.encodeComponent(widget.peerId)}'));
      if (resp.statusCode != 200) return;
      final data = jsonDecode(resp.body);
      if (data is Map<String, dynamic> && mounted) setState(() => _info = data);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final info = _info;
    if (info == null) return const SizedBox.shrink();
    final company = (info['company'] ?? '').toString();
    late final IconData icon;
    late final Color color;
    late final String text;
    switch (info['status']) {
      case 'verified':
        icon = Icons.verified;
        color = const Color(0xff1f9d5c);
        text = 'Verified company: $company';
        break;
      case 'company':
        icon = Icons.info_outline;
        color = const Color(0xffb7791f);
        text = 'Company: $company (not verified by Remotless)';
        break;
      case 'blocked':
        icon = Icons.block;
        color = const Color(0xffc0392b);
        text = 'Blocked for abuse. Do not accept.';
        break;
      default:
        icon = Icons.warning_amber_rounded;
        color = const Color(0xffc0392b);
        text = 'Not a Remotless company account. Remotless never calls you. '
            'Only accept if you asked this person for help.';
    }
    // Scam shield 2.0: the server adds a risk level and plain reasons ("tried to reach 7 computers
    // today"). Shown under the note when the risk is not low; older servers send none.
    final reasons = (info['risk'] != null && info['risk'] != 'low' && info['reasons'] is List)
        ? (info['reasons'] as List).map((e) => e.toString()).where((e) => e.isNotEmpty)
            // the note above already says this for unknown IDs
            .where((e) => !(info['status'] == 'unknown' && e.startsWith('Not a Remotless')))
            .toList()
        : <String>[];
    final high = info['risk'] == 'high';
    return Container(
      margin: const EdgeInsets.only(top: 6, right: 6),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(6)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, size: 16, color: color),
              const SizedBox(width: 6),
              Expanded(
                child: Text(text,
                    style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w600)),
              ),
            ],
          ),
          if (high)
            Padding(
              padding: const EdgeInsets.only(top: 4, left: 22),
              child: Text('High risk: this looks like a scam pattern.',
                  style: TextStyle(color: const Color(0xffc0392b), fontSize: 12, fontWeight: FontWeight.w700)),
            ),
          for (final r in reasons.take(3))
            Padding(
              padding: const EdgeInsets.only(top: 2, left: 22),
              child: Text('• $r', style: const TextStyle(color: Color(0xff444444), fontSize: 11)),
            ),
        ],
      ),
    );
  }
}
