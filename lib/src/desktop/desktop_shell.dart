import 'dart:async';

import 'package:flutter/material.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import '../session/app_controller.dart';

/// Windows: the window and the tray icon. Closing the window keeps the app running in the tray (so new-message
/// notifications keep coming) unless the user turned that off; "退出" in the tray menu really quits.
class DesktopShell with TrayListener, WindowListener {
  DesktopShell({required this.controller, this.startHidden = false});

  final AppController controller;

  /// Started with Windows (`--background`): stay in the tray until the user opens the window.
  final bool startHidden;
  int _lastUnread = -1;

  Future<void> init() async {
    await windowManager.ensureInitialized();
    const options = WindowOptions(size: Size(1100, 760), minimumSize: Size(420, 520), center: true, title: 'NyaSmsForward');
    await windowManager.waitUntilReadyToShow(options, () async {
      if (startHidden) return;
      await windowManager.show();
      await windowManager.focus();
    });
    // The close button is ours to interpret: hide to the tray or really close.
    await windowManager.setPreventClose(true);
    windowManager.addListener(this);

    trayManager.addListener(this);
    await trayManager.setIcon('assets/tray_icon.ico');
    await trayManager.setToolTip('NyaSmsForward');
    await trayManager.setContextMenu(Menu(items: [
      MenuItem(key: 'show', label: '打开 NyaSmsForward'),
      MenuItem.separator(),
      MenuItem(key: 'quit', label: '退出'),
    ]));
    controller.addListener(_onController);
  }

  /// The tooltip shows the unread count, so the tray icon answers "is there anything new?" without opening the window.
  void _onController() {
    if (controller.unread == _lastUnread) return;
    _lastUnread = controller.unread;
    unawaited(trayManager.setToolTip(_lastUnread > 0 ? 'NyaSmsForward · $_lastUnread 条未读' : 'NyaSmsForward'));
  }

  /// Whether the user is looking at the app right now (then a toast would only be noise).
  Future<bool> isInFront() async => await windowManager.isVisible() && await windowManager.isFocused() && !await windowManager.isMinimized();

  Future<void> showAndFocus() async {
    if (await windowManager.isMinimized()) await windowManager.restore();
    await windowManager.show();
    await windowManager.focus();
  }

  Future<void> quit() async {
    controller.removeListener(_onController);
    await trayManager.destroy();
    await windowManager.setPreventClose(false);
    await windowManager.destroy();
  }

  @override
  void onWindowClose() {
    if (controller.settings.minimizeToTray) {
      unawaited(windowManager.hide());
    } else {
      unawaited(quit());
    }
  }

  @override
  void onTrayIconMouseDown() => unawaited(showAndFocus());

  @override
  void onTrayIconRightMouseDown() => unawaited(trayManager.popUpContextMenu());

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    switch (menuItem.key) {
      case 'show':
        unawaited(showAndFocus());
      case 'quit':
        unawaited(quit());
    }
  }
}
