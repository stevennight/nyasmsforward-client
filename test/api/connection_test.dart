import 'package:client/src/api/connection.dart';
import 'package:flutter_test/flutter_test.dart';

/// docs/协议.md §2.2 — same cases as client-node's ConnectionTest.
void main() {
  group('Connection.classify', () {
    test('a 401 with one of our token error codes means the token is dead', () {
      for (final code in ['token_revoked', 'token_invalid', 'token_expired']) {
        expect(Connection.classify(httpStatus: 401, errorCode: code), ConnectionVerdict.needsPairing, reason: code);
      }
    });

    test('a bare 401 or 403 or 404 keeps the token and suspects the address', () {
      expect(Connection.classify(httpStatus: 401), ConnectionVerdict.addressSuspect);
      expect(Connection.classify(httpStatus: 401, errorCode: 'something_else'), ConnectionVerdict.addressSuspect);
      expect(Connection.classify(httpStatus: 403), ConnectionVerdict.addressSuspect);
      expect(Connection.classify(httpStatus: 404, errorCode: 'not_found'), ConnectionVerdict.addressSuspect);
    });

    test('network failures and server trouble are transient', () {
      expect(Connection.classify(), ConnectionVerdict.transient);
      for (final status in [408, 429, 500, 502, 503, 504, 520]) {
        expect(Connection.classify(httpStatus: status), ConnectionVerdict.transient, reason: 'status $status');
      }
      // Even a token error code is ignored when the status is not 401: a 5xx must never sign the client out.
      expect(Connection.classify(httpStatus: 503, errorCode: 'token_revoked'), ConnectionVerdict.transient);
    });

    test('websocket close 4401 follows the same rule', () {
      expect(
        Connection.classify(errorCode: 'token_revoked', websocketCloseCode: Connection.wsUnauthorized),
        ConnectionVerdict.needsPairing,
      );
      expect(Connection.classify(websocketCloseCode: Connection.wsUnauthorized), ConnectionVerdict.transient);
      expect(Connection.classify(errorCode: 'token_revoked', websocketCloseCode: 1006), ConnectionVerdict.transient);
    });
  });

  group('Backoff', () {
    test('starts at one second and doubles', () {
      expect(Backoff.delay(0, 0), const Duration(seconds: 1));
      expect(Backoff.delay(1, 0), const Duration(seconds: 2));
      expect(Backoff.delay(2, 0), const Duration(seconds: 4));
      expect(Backoff.delay(8, 0), const Duration(seconds: 256));
    });

    test('is capped at five minutes and never overflows', () {
      expect(Backoff.delay(9, 0), const Duration(minutes: 5));
      expect(Backoff.delay(50, 0), const Duration(minutes: 5));
      expect(Backoff.delay(1 << 30, 0), const Duration(minutes: 5));
    });

    test('jitter adds at most twenty percent', () {
      expect(Backoff.delay(0, 1), const Duration(milliseconds: 1200));
      expect(Backoff.delay(20, 0.999) <= const Duration(minutes: 6), isTrue);
      final mid = Backoff.delay(3, 0.5).inMilliseconds;
      expect(mid, inInclusiveRange(8000, 9600));
    });
  });
}
