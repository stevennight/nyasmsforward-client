import 'package:client/src/api/protocol.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('SendPolicy', () {
    test('unknown or missing values fall back to the safest policy', () {
      expect(SendPolicy.fromWire(null), SendPolicy.off);
      expect(SendPolicy.fromWire(''), SendPolicy.off);
      expect(SendPolicy.fromWire('everything'), SendPolicy.off);
      expect(SendPolicy.fromWire('reply'), SendPolicy.reply);
      expect(SendPolicy.fromWire('any'), SendPolicy.any);
    });

    test('the stricter layer wins', () {
      expect(SendPolicy.stricter(SendPolicy.off, SendPolicy.any), SendPolicy.off);
      expect(SendPolicy.stricter(SendPolicy.any, SendPolicy.off), SendPolicy.off);
      expect(SendPolicy.stricter(SendPolicy.any, SendPolicy.reply), SendPolicy.reply);
      expect(SendPolicy.stricter(SendPolicy.any, SendPolicy.any), SendPolicy.any);
    });
  });

  group('Scopes', () {
    test('parses the wire form', () {
      final s = Scopes.fromWire(['read', 'reply']);
      expect(s.canRead, isTrue);
      expect(s.canReply, isTrue);
      expect(s.canSend, isFalse);
    });

    test('ignores scopes a newer server may add, and non-string junk', () {
      final s = Scopes.fromWire(['read', 'admin', 42, null]);
      expect(s.granted, {Scope.read});
    });

    test('no scopes means no permissions', () {
      final s = Scopes.fromWire(null);
      expect(s.canRead || s.canReply || s.canSend, isFalse);
    });
  });

  test('only the three token errors count as a dead token', () {
    expect(ErrorCodes.deadToken, {'token_revoked', 'token_invalid', 'token_expired'});
    expect(ErrorCodes.deadToken.contains(ErrorCodes.scopeDenied), isFalse);
    expect(ErrorCodes.deadToken.contains(ErrorCodes.policyDenied), isFalse);
  });
}
