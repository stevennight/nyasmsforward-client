import 'package:flutter/material.dart';

import '../pairing/connect_screen.dart';
import '../session/app_controller.dart';
import '../ui/home_screen.dart';
import 'theme.dart';

class NyaApp extends StatelessWidget {
  const NyaApp({super.key, this.home, this.controller, this.onScan});

  /// Overridable so tests can render a specific screen.
  final Widget? home;

  /// The connected app's state. Without it (and without [home]) only the connect form is shown.
  final AppController? controller;

  /// Scans a pairing QR code (Android). Null hides the scan button.
  final Future<String?> Function(BuildContext context)? onScan;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'NyaSmsForward',
      debugShowCheckedModeBanner: false,
      theme: lightTheme,
      darkTheme: darkTheme,
      themeMode: ThemeMode.system,
      home: home ?? (controller == null ? const ConnectScreen() : _Root(controller: controller!, onScan: onScan)),
    );
  }
}

/// Picks the screen from the controller's phase: a short splash while the stored token is checked, the connect form
/// when there is no usable connection, otherwise the app.
class _Root extends StatelessWidget {
  const _Root({required this.controller, this.onScan});

  final AppController controller;
  final Future<String?> Function(BuildContext context)? onScan;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) => switch (controller.phase) {
        AppPhase.starting => const Scaffold(body: Center(child: CircularProgressIndicator())),
        AppPhase.needsConnect => ConnectScreen(
            onConnect: controller.connect,
            initialUrl: controller.settings.serverUrl,
            initialName: controller.settings.deviceName,
            notice: controller.banner,
            onScan: onScan,
          ),
        AppPhase.ready => HomeScreen(controller: controller),
      },
    );
  }
}
