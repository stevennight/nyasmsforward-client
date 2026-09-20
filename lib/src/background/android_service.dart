/// Android: keeps the connection to the server alive while the app is in the background, so notifications for new
/// messages arrive with the app closed (docs/开发计划.md, the foreground-service approach).
///
/// A foreground service runs a Dart isolate ([MessageWatcher]) that owns its own event stream. The UI isolate closes its
/// stream while the app is in the background (see AppController.setForeground), so there is exactly one connection at a
/// time and one place that alerts.
library;

import 'dart:async';
import 'dart:ui' show DartPluginRegistrant;

import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import '../api/api_client.dart';
import '../api/event_stream.dart';
import '../api/models.dart';
import '../notifications/notification_service.dart';
import '../pairing/token_store.dart';
import '../session/platform_hooks.dart';
import '../session/settings_store.dart';

const _serviceId = 4711;

/// Entry point of the service isolate. Must be a top-level function.
@pragma('vm:entry-point')
void backgroundServiceEntry() {
  FlutterForegroundTask.setTaskHandler(MessageWatcher());
}

/// Runs inside the foreground service: streams events and alerts about new messages.
class MessageWatcher extends TaskHandler {
  EventStreamRunner? _runner;
  ApiClient? _api;
  LocalNotificationService? _notifier;
  ClientSettings _settings = const ClientSettings();
  bool _uiForeground = false;
  final _notifiedUnread = <int>{};

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    DartPluginRegistrant.ensureInitialized(); // this isolate starts without plugins (storage, notifications)
    // Started by the app: the app is on screen and shows messages itself (it says so again once the service is up).
    // Started by the system (reboot, update, restart after being killed): nobody is looking, so alert.
    _uiForeground = starter == TaskStarter.developer;
    await _connect();
  }

  Future<void> _connect() async {
    _runner?.stop();
    _api?.close();
    final token = await SecureTokenStore().read();
    _settings = await PrefsSettingsStore().load();
    final url = _settings.serverUrl;
    if (token == null || url == null) {
      await FlutterForegroundTask.stopService(); // signed out meanwhile: nothing to watch
      return;
    }
    _notifier ??= LocalNotificationService(
      // A tap or button of a notification is handled by the app (or the background handler), never by this isolate.
      handlers: NotificationHandlers(
        copyCode: (_) async {},
        open: (_) {},
        reply: (to, text) => replyFromStorage(to.messageId, text),
      ),
    );
    await _notifier!.init();
    final api = _api = ApiClient(baseUrl: url, token: token);
    final runner = _runner = EventStreamRunner(
      client: api,
      onEvent: _onEvent,
      onConnected: () {
        // A new service isolate has no Last-Event-ID. Fetch unread rows so a
        // service restart cannot strand a message until the UI is opened.
        if (!_uiForeground) unawaited(_notifyUnread(api));
      },
      onStatus: _onStatus,
    );
    unawaited(runner.run());
  }

  void _onEvent(ServerEvent e) {
    switch (e) {
      case MessageEvent(:final message, :final notify):
        // Messages sent on the SIM phone are history for this client and should not make a notification.
        if (notify &&
            message.isIncoming &&
            _settings.notifications &&
            !_uiForeground) {
          unawaited(
            _notifier!.showMessage(
              message,
              canReply: _settings.scopes.contains('reply'),
            ),
          );
        }
      case ReadEvent(:final ids) || DeletedEvent(:final ids):
        // Read (or deleted) on another device: the alert is stale.
        unawaited(_notifier!.cancelMessages(ids));
      default:
        break;
    }
  }

  void _onStatus(StreamStatus s) {
    if (s == StreamStatus.live) {
      FlutterForegroundTask.sendDataToMain({'service': 'live'});
    } else if (s == StreamStatus.waiting) {
      // The service exists, but its socket is not currently live. The UI can
      // temporarily keep its own stream as a fallback.
      FlutterForegroundTask.sendDataToMain({'service': 'waiting'});
    }
    if (s == StreamStatus.tokenDead || s == StreamStatus.forbidden) {
      // The UI decides what to show (it signs out on a dead token); the service has nothing left to watch.
      FlutterForegroundTask.sendDataToMain({'stopped': s.name});
      unawaited(FlutterForegroundTask.stopService());
    }
  }

  Future<void> _notifyUnread(ApiClient api) async {
    if (!_settings.notifications || _uiForeground) return;
    try {
      for (final message in await api.unreadMessages()) {
        if (!message.isIncoming || message.backfill || !_notifiedUnread.add(message.id)) continue;
        await _notifier?.showMessage(
          message,
          canReply: _settings.scopes.contains('reply'),
        );
      }
      if (_notifiedUnread.length > 512) {
        _notifiedUnread.removeAll(
          _notifiedUnread.take(_notifiedUnread.length - 256).toList(),
        );
      }
    } on Object {
      // A transient REST failure must not take down the live stream.
    }
  }

  @override
  void onReceiveData(Object data) {
    if (data is! Map) return;
    if (data['foreground'] is bool) _uiForeground = data['foreground'] as bool;
    if (data['reload'] == true) {
      unawaited(_connect()); // address, token or notification setting changed
    }
  }

  @override
  void onRepeatEvent(DateTime timestamp) {}

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {
    FlutterForegroundTask.sendDataToMain({'service': 'stopped'});
    _runner?.stop();
    _api?.close();
  }
}

/// The UI side: starts, stops and talks to the service.
abstract final class AndroidBackground {
  static bool _initialised = false;

  static void _init() {
    if (_initialised) return;
    _initialised = true;
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'nyasms_background',
        channelName: '后台连接',
        channelDescription: '保持与服务器的连接，这样应用关闭后也能收到新短信通知',
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
      ),
      iosNotificationOptions: const IOSNotificationOptions(),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.nothing(),
        autoRunOnBoot: true,
        autoRunOnMyPackageReplaced: true,
        allowWakeLock: true,
        allowWifiLock: true,
      ),
    );
  }

  /// Must be called once, before `runApp`, so the UI can receive what the service sends.
  static void initCommunication() =>
      FlutterForegroundTask.initCommunicationPort();

  static Future<bool> get isRunning => FlutterForegroundTask.isRunningService;

  /// Starts the service and reports whether Android accepted the request.
  ///
  /// `flutter_foreground_task` returns a [ServiceRequestFailure] instead of
  /// throwing for many Android-side failures (missing permissions, a vendor
  /// policy, or a start timeout). The coordinator must not hand the live
  /// stream away unless the service really started.
  static Future<bool> start() async {
    _init();
    if (await FlutterForegroundTask.isRunningService) {
      FlutterForegroundTask.sendDataToTask({'reload': true});
      return true;
    }
    final result = await FlutterForegroundTask.startService(
      serviceId: _serviceId,
      serviceTypes: [ForegroundServiceTypes.specialUse],
      notificationTitle: 'NyaSmsForward',
      notificationText: '已连接，新短信会通知你',
      callback: backgroundServiceEntry,
    );
    return result is ServiceRequestSuccess;
  }

  static Future<void> stop() async {
    _init();
    if (await FlutterForegroundTask.isRunningService) {
      await FlutterForegroundTask.stopService();
    }
  }

  /// Tells the service whether the app is on screen (then the app shows messages itself and the service stays quiet).
  static void setForeground(bool foreground) =>
      FlutterForegroundTask.sendDataToTask({'foreground': foreground});

  /// Settings, address or token changed: the service reconnects with the new ones.
  static void reload() =>
      FlutterForegroundTask.sendDataToTask({'reload': true});

  /// Android may stop background connections to save power; being exempt keeps notifications reliable.
  static Future<bool> requestBatteryExemption() async {
    if (await FlutterForegroundTask.isIgnoringBatteryOptimizations) return true;
    return FlutterForegroundTask.requestIgnoreBatteryOptimization();
  }

  static Future<bool> get batteryExempt =>
      FlutterForegroundTask.isIgnoringBatteryOptimizations;
}

/// [BatteryExemption] on top of the foreground-service plugin.
class AndroidBatteryExemption implements BatteryExemption {
  @override
  Future<bool> isExempt() => AndroidBackground.batteryExempt;

  @override
  Future<void> request() async {
    await AndroidBackground.requestBatteryExemption();
  }
}
