/// What a failed request means for the stored token (docs/协议.md §2.2).
///
/// Getting this wrong is expensive: treating a flaky proxy as "token revoked" would sign the client out for no
/// reason. Only an explicit `401` carrying one of the server's own error codes does that; everything else keeps
/// the token and retries.
library;

import 'dart:math' as math;

import 'protocol.dart';

enum ConnectionVerdict {
  /// The server says this token is dead: go back to the connect screen, keep settings.
  needsPairing,

  /// Answered, but not like our server (bare 401 from a proxy, 403, 404): keep the token, hint the address may be wrong.
  addressSuspect,

  /// Network error, timeout, 429 or 5xx: keep the token and retry with backoff.
  transient,
}

abstract final class Connection {
  /// WebSocket close code the server uses for a rejected token.
  static const wsUnauthorized = 4401;

  /// [httpStatus] is null when no response arrived (I/O failure, timeout, TLS error).
  /// [errorCode] is the `error` field of a JSON error body, if the body was our JSON.
  static ConnectionVerdict classify({int? httpStatus, String? errorCode, int? websocketCloseCode}) {
    final dead = errorCode != null && ErrorCodes.deadToken.contains(errorCode);
    if (websocketCloseCode == wsUnauthorized) {
      return dead ? ConnectionVerdict.needsPairing : ConnectionVerdict.transient;
    }
    if (httpStatus == null) return ConnectionVerdict.transient;
    if (httpStatus == 401 && dead) return ConnectionVerdict.needsPairing;
    if (httpStatus == 401 || httpStatus == 403 || httpStatus == 404) return ConnectionVerdict.addressSuspect;
    return ConnectionVerdict.transient; // 429, 5xx (incl. 502/503/504 from a proxy), anything unexpected
  }
}

/// Reconnect delay: 1s, doubling, capped at 5 minutes, with up to 20% jitter. Retries never stop.
abstract final class Backoff {
  static const _base = Duration(seconds: 1);
  static const _cap = Duration(minutes: 5);

  /// [attempt] is 0 for the first retry. [random] is a value in [0, 1) so tests can be deterministic.
  static Duration delay(int attempt, double random) {
    final exp = math.min(_base.inMilliseconds * math.pow(2, math.min(attempt, 30)), _cap.inMilliseconds.toDouble());
    final withJitter = exp * (1 + 0.2 * random);
    return Duration(milliseconds: math.min(withJitter, _cap.inMilliseconds * 1.2).toInt());
  }
}
