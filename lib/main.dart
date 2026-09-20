import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'src/app/app.dart';
import 'src/pairing/token_store.dart';
import 'src/session/app_controller.dart';
import 'src/session/settings_store.dart';

/// Keep in sync with pubspec.yaml (`tool/check_version.dart` verifies the release).
const appVersion = String.fromEnvironment('APP_VERSION', defaultValue: '0.1.0');

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final controller = AppController(
    tokens: SecureTokenStore(),
    settingsStore: PrefsSettingsStore(),
    appVersion: appVersion,
    platform: defaultTargetPlatform == TargetPlatform.windows ? 'windows' : 'android',
  );
  runApp(NyaApp(controller: controller));
  await controller.start();
}
