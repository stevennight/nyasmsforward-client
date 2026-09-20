import 'dart:io';

import 'package:client/src/desktop/launch_at_login.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('enabling writes the Run key with the executable and --background', () async {
    final calls = <List<String>>[];
    final hook = WindowsLaunchAtLogin(
      executable: r'C:\Program Files\NyaSmsForward\NyaSmsForward.exe',
      runner: (exe, args) async {
        calls.add([exe, ...args]);
        return (exitCode: 0, output: '');
      },
    );
    await hook.set(true);
    expect(calls.single, [
      'reg', 'add', r'HKCU\Software\Microsoft\Windows\CurrentVersion\Run', '/v', 'NyaSmsForward', '/t', 'REG_SZ', '/d',
      r'"C:\Program Files\NyaSmsForward\NyaSmsForward.exe" --background', '/f',
    ]);
  });

  test('disabling deletes the value, and a value that is already gone is not an error', () async {
    final calls = <List<String>>[];
    final hook = WindowsLaunchAtLogin(runner: (exe, args) async {
      calls.add([exe, ...args]);
      return (exitCode: 1, output: 'not found');
    });
    await hook.set(false);
    expect(calls.single.sublist(0, 3), ['reg', 'delete', r'HKCU\Software\Microsoft\Windows\CurrentVersion\Run']);
    expect(await hook.isEnabled(), isFalse);
  });

  test('a failed write is reported', () async {
    final hook = WindowsLaunchAtLogin(runner: (_, _) async => (exitCode: 1, output: 'access denied'));
    await expectLater(hook.set(true), throwsStateError);
  });

  test('against the real registry (Windows only): on, seen, off', () async {
    final hook = WindowsLaunchAtLogin(executable: r'C:\Temp\nyasms-test.exe', valueName: 'NyaSmsForwardTest');
    try {
      expect(await hook.isEnabled(), isFalse);
      await hook.set(true);
      expect(await hook.isEnabled(), isTrue);
      await hook.set(false);
      expect(await hook.isEnabled(), isFalse);
    } finally {
      await hook.set(false);
    }
  }, skip: Platform.isWindows ? false : 'needs the Windows registry');
}
