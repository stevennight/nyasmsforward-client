/// What a notification for a new message says and what its buttons do. Pure Dart, so it can be tested without a
/// notification plugin and shared with the Android background service.
library;

import 'dart:convert';

import '../api/models.dart';

/// What travels with a notification so that a tap or a button can find its way back to the conversation.
class NotificationPayload {
  const NotificationPayload({required this.messageId, required this.deviceId, required this.peerKey, required this.peer, this.code});

  factory NotificationPayload.forMessage(Message m) =>
      NotificationPayload(messageId: m.id, deviceId: m.deviceId, peerKey: m.peerKey, peer: m.peer, code: m.code);

  final int messageId;
  final String deviceId;
  final String peerKey;
  final String peer;
  final String? code;

  String encode() => jsonEncode({'m': messageId, 'd': deviceId, 'k': peerKey, 'p': peer, 'c': ?code});

  static NotificationPayload? decode(String? text) {
    if (text == null || text.isEmpty) return null;
    try {
      final j = jsonDecode(text);
      if (j is! Map || j['m'] is! num) return null;
      return NotificationPayload(
        messageId: (j['m'] as num).toInt(),
        deviceId: j['d'] as String? ?? '',
        peerKey: j['k'] as String? ?? '',
        peer: j['p'] as String? ?? '',
        code: j['c'] as String?,
      );
    } on FormatException {
      return null;
    }
  }
}

/// The ids of the buttons on a message notification.
abstract final class NotificationAction {
  static const copyCode = 'copy';
  static const reply = 'reply';
}

/// Title and text of the notification for [m].
///
/// A message with a verification code leads with the code: that is what the user came for, and it is readable straight
/// from the lock screen or the toast.
({String title, String body}) contentFor(Message m) {
  final code = m.code;
  final title = code != null && code.isNotEmpty ? '${m.peer} · 验证码 $code' : m.peer;
  return (title: title, body: m.body);
}

/// Which buttons to offer: copying needs a code, replying needs the permission and a number that can be replied to.
List<String> actionsFor(Message m, {required bool canReply}) => [
      if (m.code != null && m.code!.isNotEmpty) NotificationAction.copyCode,
      if (canReply && m.isIncoming && _looksLikeNumber(m.peer)) NotificationAction.reply,
    ];

bool _looksLikeNumber(String peer) => RegExp(r'^\+?[0-9 \-()]+$').hasMatch(peer.trim());
