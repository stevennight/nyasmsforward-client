/// The content of the pairing QR code / link (docs/协议.md §3.2):
/// `nyasmsforward://pair?server=https://sms.example.com&code=483920`. It carries no long-lived credential.
library;

class PairLink {
  const PairLink({required this.server, required this.code});

  final String server;
  final String code;

  /// Null when [text] is not a pairing link, or lacks the address or a 6-digit code.
  static PairLink? tryParse(String text) {
    final uri = Uri.tryParse(text.trim());
    if (uri == null || uri.scheme != 'nyasmsforward' || uri.host != 'pair') return null;
    final server = uri.queryParameters['server'];
    final code = (uri.queryParameters['code'] ?? '').replaceAll(RegExp(r'\D'), '');
    if (server == null || server.isEmpty || code.length != 6) return null;
    return PairLink(server: server, code: code);
  }
}
