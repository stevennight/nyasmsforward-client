import 'package:flutter_test/flutter_test.dart';

import '../../tool/version_check.dart';

void main() {
  const pubspec = 'name: client\nversion: 0.1.0+1000\nenvironment:\n  sdk: ^3.13.2\n';

  test('the build number packs major, minor and patch', () {
    expect(buildNumberFor('0.1.0'), 1000);
    expect(buildNumberFor('1.2.3'), 1002003);
    expect(buildNumberFor('12.0.7'), 12000007);
    expect(() => buildNumberFor('1.2'), throwsFormatException);
  });

  test('a consistent repository has no problems, with or without a tag', () {
    expect(checkVersions(versionFile: '0.1.0\n', pubspec: pubspec), isEmpty);
    expect(checkVersions(versionFile: '0.1.0', pubspec: pubspec, tag: 'v0.1.0'), isEmpty);
  });

  test('a tag that does not match VERSION is reported', () {
    final problems = checkVersions(versionFile: '0.1.0', pubspec: pubspec, tag: 'v0.2.0');
    expect(problems, hasLength(1));
    expect(problems.single, contains('v0.2.0'));
  });

  test('pubspec drifting from VERSION is reported, including a wrong build number', () {
    expect(checkVersions(versionFile: '0.2.0', pubspec: pubspec), hasLength(2)); // version and build number differ
    expect(
      checkVersions(versionFile: '0.1.0', pubspec: 'version: 0.1.0+1\n').single,
      contains('+1000'),
    );
    expect(checkVersions(versionFile: '0.1.0', pubspec: 'version: 0.1.0\n').single, contains('+1000'));
    expect(checkVersions(versionFile: '0.1.0', pubspec: 'name: x\n').single, contains('no version line'));
  });

  test('VERSION must be a plain MAJOR.MINOR.PATCH within installer limits', () {
    expect(checkVersions(versionFile: '1.0', pubspec: pubspec).single, contains('MAJOR.MINOR.PATCH'));
    expect(checkVersions(versionFile: '0.1.0-dev', pubspec: pubspec).single, contains('MAJOR.MINOR.PATCH'));
    expect(checkVersions(versionFile: '256.0.0', pubspec: 'version: 256.0.0+256000000\n').single, contains('installer'));
    expect(
      checkVersions(versionFile: '1.1000.0', pubspec: 'version: 1.1000.0+2000000\n'),
      contains(contains('ambiguous')),
    );
  });

  test('the version compiled into main.dart must follow VERSION', () {
    const main = "const appVersion = String.fromEnvironment('APP_VERSION', defaultValue: '0.1.0');";
    expect(checkVersions(versionFile: '0.1.0', pubspec: pubspec, mainDart: main), isEmpty);
    expect(checkVersions(versionFile: '0.1.0', pubspec: pubspec, mainDart: main.replaceAll('0.1.0', '0.0.9')).single, contains('does not match'));
    expect(checkVersions(versionFile: '0.1.0', pubspec: pubspec, mainDart: 'void main() {}').single, contains('no APP_VERSION'));
  });
}
