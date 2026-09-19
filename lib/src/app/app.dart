import 'package:flutter/material.dart';

import '../pairing/connect_screen.dart';
import 'theme.dart';

class NyaApp extends StatelessWidget {
  const NyaApp({super.key, this.home});

  /// Overridable so tests can render a specific screen.
  final Widget? home;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'NyaSmsForward',
      debugShowCheckedModeBanner: false,
      theme: lightTheme,
      darkTheme: darkTheme,
      themeMode: ThemeMode.system,
      home: home ?? const ConnectScreen(),
    );
  }
}
