import 'package:client/src/api/server_url.dart';
import 'package:flutter_test/flutter_test.dart';

/// Same cases as client-node's ServerUrlTest: the two apps must accept and reject the same addresses.
void main() {
  ServerUrlOk ok(String url, {bool insecure = false}) => ServerUrlOk(url, insecure: insecure);
  ServerUrlInvalid bad(ServerUrlProblem p) => ServerUrlInvalid(p);

  test('https addresses are accepted and normalized', () {
    expect(ServerUrl.validate('https://sms.example.com'), ok('https://sms.example.com'));
    expect(ServerUrl.validate('  https://sms.example.com/  '), ok('https://sms.example.com'));
    expect(ServerUrl.validate('https://sms.example.com:8443/base/'), ok('https://sms.example.com:8443/base'));
  });

  test('plain http is only allowed for localhost and private networks', () {
    for (final url in [
      'http://localhost:8080',
      'http://127.0.0.1:8080',
      'http://192.168.1.5:8080',
      'http://10.0.0.2',
      'http://172.16.0.9',
      'http://172.31.255.1',
    ]) {
      expect(ServerUrl.validate(url), ok(url, insecure: true), reason: url);
    }
    for (final url in [
      'http://sms.example.com',
      'http://8.8.8.8',
      'http://172.32.0.1',
      'http://192.169.1.1',
      'http://300.1.1.1',
    ]) {
      expect(ServerUrl.validate(url), bad(ServerUrlProblem.publicHttp), reason: url);
    }
  });

  test('rejects empty input, other schemes and malformed hosts', () {
    expect(ServerUrl.validate('   '), bad(ServerUrlProblem.empty));
    expect(ServerUrl.validate('sms.example.com'), bad(ServerUrlProblem.badScheme));
    expect(ServerUrl.validate('ftp://sms.example.com'), bad(ServerUrlProblem.badScheme));
    expect(ServerUrl.validate('https://'), bad(ServerUrlProblem.badHost));
    expect(ServerUrl.validate('https://user@sms.example.com'), bad(ServerUrlProblem.badHost));
    expect(ServerUrl.validate('https://sms example.com'), bad(ServerUrlProblem.badHost));
    expect(ServerUrl.validate('https://sms.example.com:99999'), bad(ServerUrlProblem.badHost));
    expect(ServerUrl.validate('https://sms.example.com:abc'), bad(ServerUrlProblem.badHost));
  });
}
