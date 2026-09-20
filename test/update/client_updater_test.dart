import 'package:flutter_test/flutter_test.dart';

import 'package:client/src/update/client_updater.dart';

void main() {
  test('stable client versions compare numerically', () {
    final old = StableClientVersion.parse('0.9.12')!;
    final current = StableClientVersion.parse('1.0.0')!;
    expect(old.compareTo(current), lessThan(0));
    expect(StableClientVersion.parse('1.0.1')!.compareTo(current), greaterThan(0));
    expect(current.toString(), '1.0.0');
  });

  test('pre-release and malformed versions are rejected', () {
    expect(StableClientVersion.parse('v1.2.3'), isNull);
    expect(StableClientVersion.parse('1.2.3-beta'), isNull);
    expect(StableClientVersion.parse('1.2'), isNull);
    expect(StableClientVersion.parse('01.2.3'), isNull);
  });
}
