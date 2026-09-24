import 'package:flutter/material.dart';

/// The sender name Chinese service SMS start with ("【中国移动】…" → "中国移动"), or null.
String? senderBrand(String body) {
  final m = RegExp(r'^\s*[【\[]([^】\]]{1,16})[】\]]').firstMatch(body);
  return m?.group(1)?.trim();
}

const _avatarColors = [
  Color(0xFF4964D8),
  Color(0xFF0E9384),
  Color(0xFFDC6803),
  Color(0xFF7A5AF8),
  Color(0xFFD92D20),
  Color(0xFF2E90FA),
];

/// A round badge for a correspondent: the first character of the sender name when the SMS carries one, a person for
/// a mobile number, and a generic chat icon for service numbers.
class PeerAvatar extends StatelessWidget {
  const PeerAvatar({super.key, required this.peer, this.brand, this.size = 44});

  final String peer;
  final String? brand;
  final double size;

  @override
  Widget build(BuildContext context) {
    final color = _avatarColors[(brand ?? peer).hashCode.abs() % _avatarColors.length];
    final mobile = RegExp(r'^(\+?86)?1[3-9]\d{9}$').hasMatch(peer.replaceAll(' ', ''));
    final Widget child = brand != null && brand!.isNotEmpty
        ? Text(
            brand!.characters.first,
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: size * .42),
          )
        : Icon(mobile ? Icons.person : Icons.forum_outlined, color: Colors.white, size: size * .5);
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      child: child,
    );
  }
}

/// A verification code shown inline, in the list and above a conversation.
class CodePill extends StatelessWidget {
  const CodePill(this.code, {super.key});

  final String code;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
      decoration: BoxDecoration(color: scheme.primaryContainer, borderRadius: BorderRadius.circular(6)),
      child: Text(
        code,
        style: TextStyle(
          fontFamily: 'monospace',
          fontWeight: FontWeight.w700,
          fontSize: 12.5,
          letterSpacing: .5,
          color: scheme.onPrimaryContainer,
        ),
      ),
    );
  }
}
