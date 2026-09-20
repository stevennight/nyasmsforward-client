import 'dart:async';
import 'dart:ui' show DartPluginRegistrant;

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart' hide Message;

import '../api/api_client.dart';
import '../api/models.dart';
import '../pairing/token_store.dart';
import '../session/settings_store.dart';
import 'notification_content.dart';

/// Shows and clears the notifications for new messages. Behind an interface so the app logic does not depend on a plugin.
abstract interface class NotificationService {
  Future<void> init();
  Future<void> showMessage(Message m, {required bool canReply});
  Future<void> cancelMessages(Iterable<int> ids);

  /// Replaces a notification's buttons with the outcome of an inline reply ("已发送" / the error).
  Future<void> showReplyOutcome(NotificationPayload to, {required String text});
}

/// What the user did with a notification.
class NotificationHandlers {
  const NotificationHandlers({required this.copyCode, required this.open, required this.reply});

  /// Copies [code] (the app has just been brought to the foreground by the button).
  final Future<void> Function(String code) copyCode;

  /// Opens the conversation the notification belongs to.
  final void Function(NotificationPayload to) open;

  /// Sends [text] as a reply to the message of [to]; returns an error text or null. Runs in the foreground or, on
  /// Android with the app closed, in a background isolate.
  final Future<String?> Function(NotificationPayload to, String text) reply;
}

const _appUserModelId = 'app.nya.smsforward.client';
const _windowsGuid = 'b4a5b3ad-9f44-4d3a-8d77-4f0f1c6f6a11';

/// Notifications through `flutter_local_notifications`: Windows toasts and Android notifications, both with a
/// "copy code" button and an inline reply.
class LocalNotificationService implements NotificationService {
  LocalNotificationService({required this.handlers});

  final NotificationHandlers handlers;
  final _plugin = FlutterLocalNotificationsPlugin();
  bool _ready = false;

  static const _channel = AndroidNotificationChannel('messages', '新短信', description: '收到的短信，验证码可以直接复制', importance: Importance.high);

  @override
  Future<void> init() async {
    if (_ready) return;
    await _plugin.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
        windows: WindowsInitializationSettings(appName: 'NyaSmsForward', appUserModelId: _appUserModelId, guid: _windowsGuid),
      ),
      onDidReceiveNotificationResponse: (r) => unawaited(dispatchResponse(r, handlers, this)),
      onDidReceiveBackgroundNotificationResponse: notificationBackgroundHandler,
    );
    final android = _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    await android?.createNotificationChannel(_channel);
    await android?.requestNotificationsPermission();
    _ready = true;
  }

  @override
  Future<void> showMessage(Message m, {required bool canReply}) async {
    await init();
    final content = contentFor(m);
    final actions = actionsFor(m, canReply: canReply);
    final payload = NotificationPayload.forMessage(m).encode();

    final details = NotificationDetails(
      android: AndroidNotificationDetails(
        _channel.id,
        _channel.name,
        channelDescription: _channel.description,
        importance: Importance.high,
        priority: Priority.high,
        category: AndroidNotificationCategory.message,
        styleInformation: BigTextStyleInformation(content.body),
        actions: [
          if (actions.contains(NotificationAction.copyCode))
            const AndroidNotificationAction(NotificationAction.copyCode, '复制验证码', showsUserInterface: true, cancelNotification: false),
          if (actions.contains(NotificationAction.reply))
            const AndroidNotificationAction(
              NotificationAction.reply,
              '回复',
              inputs: [AndroidNotificationActionInput(label: '回复内容')],
              showsUserInterface: false,
              cancelNotification: false,
            ),
        ],
      ),
      windows: WindowsNotificationDetails(
        actions: [
          if (actions.contains(NotificationAction.copyCode)) const WindowsAction(content: '复制验证码', arguments: NotificationAction.copyCode),
          if (actions.contains(NotificationAction.reply)) const WindowsAction(content: '发送', arguments: NotificationAction.reply, inputId: 'reply'),
        ],
        inputs: [
          if (actions.contains(NotificationAction.reply)) const WindowsTextInput(id: 'reply', placeHolderContent: '回复这个号码'),
        ],
      ),
    );
    await _plugin.show(id: m.id, title: content.title, body: content.body, notificationDetails: details, payload: payload);
  }

  @override
  Future<void> cancelMessages(Iterable<int> ids) async {
    if (!_ready) return;
    for (final id in ids) {
      await _plugin.cancel(id: id);
    }
  }

  @override
  Future<void> showReplyOutcome(NotificationPayload to, {required String text}) async {
    await init();
    // Same id: replaces the notification whose button was used, so Android stops showing the reply spinner.
    await _plugin.show(
      id: to.messageId,
      title: to.peer,
      body: text,
      notificationDetails: const NotificationDetails(
        android: AndroidNotificationDetails('messages', '新短信', importance: Importance.defaultImportance, onlyAlertOnce: true, timeoutAfter: 8000),
      ),
      payload: to.encode(),
    );
  }
}

/// Routes a tap or a button of a notification to the right handler. Kept as a free function so it can be tested.
Future<void> dispatchResponse(NotificationResponse r, NotificationHandlers handlers, NotificationService notifier) async {
  final to = NotificationPayload.decode(r.payload);
  if (to == null) return;
  switch (r.actionId) {
    case NotificationAction.copyCode:
      final code = to.code;
      if (code != null && code.isNotEmpty) await handlers.copyCode(code);
    case NotificationAction.reply:
      // Android delivers the typed text in `input`, Windows in the `data` map under the input's id.
      final text = (r.input ?? r.data['reply']?.toString() ?? '').trim();
      if (text.isEmpty) return;
      final error = await handlers.reply(to, text);
      await notifier.showReplyOutcome(to, text: error == null ? '已回复：$text' : '回复失败：$error');
    case null || '':
      handlers.open(to);
  }
}

/// Android calls this in a background isolate when a notification button that does not open the app is used and the app
/// is not in the foreground (the inline reply). It has no access to the running app, so it rebuilds what it needs from
/// storage: the token from the secure store and the address from the settings.
@pragma('vm:entry-point')
Future<void> notificationBackgroundHandler(NotificationResponse response) async {
  DartPluginRegistrant.ensureInitialized(); // this isolate has no plugins registered yet (storage, notifications)
  final service = LocalNotificationService(
    handlers: NotificationHandlers(
      copyCode: (_) async {},
      open: (_) {},
      reply: (to, text) => replyFromStorage(to.messageId, text),
    ),
  );
  await dispatchResponse(response, service.handlers, service);
}

/// Sends a reply using only what is stored on the device. Returns an error text, or null when the task was accepted.
Future<String?> replyFromStorage(int messageId, String text, {TokenStore? tokens, SettingsStore? settings, ApiClient Function(String url, String token)? api}) async {
  final token = await (tokens ?? SecureTokenStore()).read();
  final url = (await (settings ?? PrefsSettingsStore()).load()).serverUrl;
  if (token == null || url == null) return '还没有连接到服务器';
  final client = api?.call(url, token) ?? ApiClient(baseUrl: url, token: token);
  try {
    await client.reply(messageId, text);
    return null;
  } on ApiException catch (e) {
    return e.text;
  } finally {
    client.close();
  }
}

/// Whether notifications can be shown here at all (the plugin supports Android and Windows in this app).
bool get notificationsSupported => defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.windows;
