import 'dart:io';

import '../session/platform_hooks.dart';

/// Runs a command and returns its exit code and output. Injectable so the registry commands can be tested.
typedef CommandRunner = Future<({int exitCode, String output})> Function(String executable, List<String> arguments);

Future<({int exitCode, String output})> _run(String executable, List<String> arguments) async {
  final r = await Process.run(executable, arguments);
  return (exitCode: r.exitCode, output: '${r.stdout}');
}

/// Windows "start with Windows" through the per-user Run key (no elevation, no extra plugin). The app is started with
/// `--background`, which keeps the window hidden in the tray.
class WindowsLaunchAtLogin implements LaunchAtLogin {
  WindowsLaunchAtLogin({String? executable, CommandRunner? runner, this.valueName = defaultValueName})
      : _exe = executable ?? Platform.resolvedExecutable,
        _runner = runner ?? _run;

  static const key = r'HKCU\Software\Microsoft\Windows\CurrentVersion\Run';
  static const defaultValueName = 'NyaSmsForward';

  final String valueName;

  final String _exe;
  final CommandRunner _runner;

  @override
  Future<bool> isEnabled() async {
    final r = await _runner('reg', ['query', key, '/v', valueName]);
    return r.exitCode == 0;
  }

  @override
  Future<void> set(bool enabled) async {
    final r = enabled
        ? await _runner('reg', ['add', key, '/v', valueName, '/t', 'REG_SZ', '/d', '"$_exe" --background', '/f'])
        : await _runner('reg', ['delete', key, '/v', valueName, '/f']);
    if (r.exitCode != 0 && enabled) throw StateError('could not write the Run key');
  }
}
