import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import '../session/app_controller.dart';
import 'android_service.dart';

/// Android: decides when the background service runs and hands the live connection over between the app and the service.
///
/// The service runs while the client is connected, may read, and notifications are switched on. While the app is on screen
/// the app holds the connection itself; when it goes to the background the service takes over, and back again.
class BackgroundCoordinator with WidgetsBindingObserver {
  BackgroundCoordinator(this.controller);

  final AppController controller;
  bool _serviceRunning = false;
  bool _syncing = false, _syncAgain = false;
  String? _lastUrl;
  bool _lastNotifications = true;

  void attach() {
    WidgetsBinding.instance.addObserver(this);
    controller.addListener(_onController);
    FlutterForegroundTask.addTaskDataCallback(_onServiceData);
    // Cover a controller that was already started before the coordinator was attached.
    unawaited(_sync(reload: true));
  }

  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    controller.removeListener(_onController);
    FlutterForegroundTask.removeTaskDataCallback(_onServiceData);
  }

  bool get _wanted =>
      controller.phase == AppPhase.ready && controller.settings.notifications && controller.scopes.canRead && controller.settings.serverUrl != null;

  void _onController() {
    final url = controller.settings.serverUrl;
    final notes = controller.settings.notifications;
    final changed = url != _lastUrl || notes != _lastNotifications;
    _lastUrl = url;
    _lastNotifications = notes;
    unawaited(_sync(reload: changed));
  }

  Future<void> _sync({bool reload = false}) async {
    if (_syncing) {
      _syncAgain = true;
      return;
    }
    _syncing = true;
    try {
      do {
        _syncAgain = false;
        if (_wanted && !_serviceRunning) {
          await AndroidBackground.start();
          _serviceRunning = true;
          AndroidBackground.setForeground(_isForeground);
        } else if (!_wanted && _serviceRunning) {
          await AndroidBackground.stop();
          _serviceRunning = false;
          controller.setForeground(true); // nobody else holds the connection any more
        } else if (_serviceRunning && reload) {
          AndroidBackground.reload();
        }
      } while (_syncAgain);
    } on Object {
      // The service could not start (e.g. Android refused it in the background): the app keeps its own connection.
      _serviceRunning = false;
    } finally {
      _syncing = false;
    }
  }

  bool _isForeground = true;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final foreground = state == AppLifecycleState.resumed;
    // Only hand the connection to the service when it really runs; otherwise the app keeps it and nothing is lost.
    if (foreground) {
      _isForeground = true;
      if (_serviceRunning) AndroidBackground.setForeground(true);
      controller.setForeground(true);
    } else if (state == AppLifecycleState.paused || state == AppLifecycleState.hidden) {
      _isForeground = false;
      if (_serviceRunning) {
        AndroidBackground.setForeground(false);
        controller.setForeground(false);
      } else {
        // A service start can be rejected by Android (missing permission, a vendor battery policy, or a race while
        // the app is leaving the foreground). Keep the app's stream alive in that case, and retry the service start;
        // stopping the only live stream here would make background notifications disappear completely.
        unawaited(_sync(reload: true));
      }
    }
  }

  /// The service ended by itself (the token was rejected, or the read permission is gone): let the app find out why.
  void _onServiceData(Object data) {
    if (data is Map && data['stopped'] != null) {
      _serviceRunning = false;
      controller.setForeground(true);
      unawaited(controller.refreshAll());
    }
  }
}
