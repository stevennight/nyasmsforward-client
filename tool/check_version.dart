// Usage: dart run tool/check_version.dart [vX.Y.Z]
// Exits 1 (printing every problem) when VERSION, pubspec.yaml and the optional tag disagree.
import 'dart:io';

import 'version_check.dart';

void main(List<String> args) {
  final problems = checkVersions(
    versionFile: File('VERSION').readAsStringSync(),
    pubspec: File('pubspec.yaml').readAsStringSync(),
    tag: args.isEmpty ? null : args.first,
    mainDart: File('lib/main.dart').readAsStringSync(),
  );
  if (problems.isEmpty) {
    stdout.writeln('version OK: ${File('VERSION').readAsStringSync().trim()}');
    return;
  }
  for (final p in problems) {
    stderr.writeln('version check failed: $p');
  }
  exit(1);
}
