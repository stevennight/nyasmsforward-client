/// Protocol constants shared with the server (docs/协议.md in nyasmsforward-server).
/// This repo keeps its own copy of the definitions; the contract is the document, not shared code.
library;

/// How much a phone may be made to send. Ordered strictest to loosest, so the effective policy of two
/// layers (platform limit, phone setting) is the smaller index.
enum SendPolicy {
  /// Reject every send task. The default.
  off,

  /// Only replies, and only to numbers that recently messaged the phone.
  reply,

  /// Replies plus new messages to any number.
  any;

  /// Unknown or missing values fall back to the safest policy.
  static SendPolicy fromWire(String? value) {
    for (final p in SendPolicy.values) {
      if (p.name == value) return p;
    }
    return SendPolicy.off;
  }

  static SendPolicy stricter(SendPolicy a, SendPolicy b) => a.index <= b.index ? a : b;
}

/// What a client token may do (docs/协议.md §3): `read`, `reply`, `send`.
enum Scope {
  read,
  reply,
  send;

  static Scope? tryParse(String? value) {
    for (final s in Scope.values) {
      if (s.name == value) return s;
    }
    return null;
  }
}

/// The scopes granted to this client. Unknown values sent by a newer server are ignored, not fatal.
class Scopes {
  const Scopes(this.granted);

  factory Scopes.fromWire(Iterable<Object?>? values) =>
      Scopes({for (final v in values ?? const []) ?Scope.tryParse(v is String ? v : null)});

  final Set<Scope> granted;

  bool get canRead => granted.contains(Scope.read);
  bool get canReply => granted.contains(Scope.reply);
  bool get canSend => granted.contains(Scope.send);
}

/// Error codes of the `{"error": "<code>"}` body. Clients key off the code, never off the message.
abstract final class ErrorCodes {
  static const tokenRevoked = 'token_revoked';
  static const tokenInvalid = 'token_invalid';
  static const tokenExpired = 'token_expired';
  static const scopeDenied = 'scope_denied';
  static const policyDenied = 'policy_denied';
  static const recipientNotAllowed = 'recipient_not_allowed';
  static const totpRequired = 'totp_required';
  static const invalidTotp = 'invalid_totp';
  static const replyNotSupported = 'reply_not_supported';
  static const pairCodeRequired = 'pair_code_required';

  /// Codes that mean "this token is dead".
  static const deadToken = {tokenRevoked, tokenInvalid, tokenExpired};
}
