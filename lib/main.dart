import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'src/app/app.dart';
import 'src/background/android_service.dart';
import 'src/background/background_coordinator.dart';
import 'src/desktop/desktop_shell.dart';
import 'src/desktop/launch_at_login.dart';
import 'src/session/platform_hooks.dart';
import 'src/notifications/notification_service.dart';
import 'src/pairing/qr_scanner.dart';
import 'src/pairing/token_store.dart';
import 'src/session/app_controller.dart';
import 'src/session/settings_store.dart';
import 'src/ui/format.dart';

/// Keep in sync with pubspec.yaml (`tool/check_version.dart` verifies the release).
const appVersion = String.fromEnvironment('APP_VERSION', defaultValue: '0.2.11');

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  final isAndroid = defaultTargetPlatform == TargetPlatform.android;
  final isWindows = defaultTargetPlatform == TargetPlatform.windows;
  if (isAndroid) AndroidBackground.initCommunication(); // lets the background service talk to this isolate

  late final AppController controller;
  DesktopShell? shell;
  LocalNotificationService? notifier;

  if (isAndroid || isWindows) {
    notifier = LocalNotificationService(
      handlers: NotificationHandlers(
        copyCode: (code) async {
          await copyText(code);
        },
        open: (to) {
          unawaited(shell?.showAndFocus());
          final match = controller.conversations.where(
            (c) => c.deviceId == to.deviceId && c.peerKey == to.peerKey,
          );
          if (match.isNotEmpty) {
            unawaited(controller.openConversation(match.first));
          }
        },
        reply: (to, text) => controller.replyToMessage(to.messageId, text),
      ),
    );
  }

  controller = AppController(
    tokens: SecureTokenStore(),
    settingsStore: PrefsSettingsStore(),
    appVersion: appVersion,
    platform: isWindows ? 'windows' : 'android',
    hooks: PlatformHooks(
      launchAtLogin: isWindows ? WindowsLaunchAtLogin() : null,
      battery: isAndroid ? AndroidBatteryExemption() : null,
    ),
    onIncoming: (m) async {
      // Android normally stays quiet while the app is on screen, but the user
      // can opt into a system notification there as well. Windows alerts only
      // when its window is not in front.
      final n = notifier;
      if (n == null || !controller.settings.notifications) return;
      if (isAndroid &&
          controller.appVisible &&
          !controller.settings.foregroundNotifications) {
        return;
      }
      if (isWindows && (await shell?.isInFront() ?? false)) return;
      await n.showMessage(m, canReply: controller.scopes.canReply);
    },
  );

  if (isWindows) {
    shell = DesktopShell(
      controller: controller,
      startHidden: args.contains('--background'),
    );
    await shell.init();
  }
  if (isAndroid) BackgroundCoordinator(controller).attach();
  if (notifier != null) unawaited(notifier.init());

  runApp(NyaApp(controller: controller, onScan: isAndroid ? scanQrCode : null));
  await controller.start();
}
