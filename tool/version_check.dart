/// Consistency rules between `VERSION`, `pubspec.yaml` and the release tag.
///
/// - `VERSION` is `MAJOR.MINOR.PATCH` and is the single source of truth.
/// - `pubspec.yaml` must say `version: MAJOR.MINOR.PATCH+BUILD` with the same triple, and
///   `BUILD = major*1000000 + minor*1000 + patch` (the same formula client-node uses for its versionCode).
/// - The `APP_VERSION` default in `lib/main.dart` (what the app tells the server) equals `VERSION`.
/// - When a tag is given (release builds), it must be `v<VERSION>`.
library;

final _semver = RegExp(r'^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$');

/// The Android versionCode / Windows-independent build number for [version].
int buildNumberFor(String version) {
  final m = _semver.firstMatch(version);
  if (m == null) throw FormatException('not MAJOR.MINOR.PATCH: "$version"');
  return int.parse(m[1]!) * 1000000 + int.parse(m[2]!) * 1000 + int.parse(m[3]!);
}

/// Returns a list of problems; empty means everything is consistent.
List<String> checkVersions({required String versionFile, required String pubspec, String? tag, String? mainDart}) {
  final problems = <String>[];
  final version = versionFile.trim();

  final m = _semver.firstMatch(version);
  if (m == null) {
    problems.add('VERSION must be MAJOR.MINOR.PATCH, got "$version"');
    return problems;
  }
  final major = int.parse(m[1]!), minor = int.parse(m[2]!), patch = int.parse(m[3]!);
  if (major > 255 || minor > 255 || patch > 65535) {
    problems.add('VERSION $version exceeds Windows installer version limits (255.255.65535)');
  }
  if (minor > 999 || patch > 999) {
    problems.add('VERSION $version would make the build number ambiguous (minor and patch must be <= 999)');
  }

  final line = RegExp(r'^version:\s*(\S+)\s*$', multiLine: true).firstMatch(pubspec);
  if (line == null) {
    problems.add('pubspec.yaml has no version line');
  } else {
    final parts = line.group(1)!.split('+');
    if (parts[0] != version) problems.add('pubspec.yaml version ${parts[0]} does not match VERSION $version');
    final expected = buildNumberFor(version);
    if (parts.length != 2 || parts[1] != '$expected') {
      problems.add('pubspec.yaml build number must be +$expected for $version, got "${parts.length > 1 ? parts[1] : ''}"');
    }
  }

  // The app reports its version when it connects, so the default compiled into lib/main.dart must not drift.
  if (mainDart != null) {
    final m = RegExp(r"APP_VERSION',\s*defaultValue:\s*'([^']*)'").firstMatch(mainDart);
    if (m == null) {
      problems.add('lib/main.dart has no APP_VERSION default');
    } else if (m.group(1) != version) {
      problems.add('lib/main.dart APP_VERSION default ${m.group(1)} does not match VERSION $version');
    }
  }

  if (tag != null && tag != 'v$version') {
    problems.add('tag $tag does not match VERSION $version (expected v$version)');
  }
  return problems;
}
