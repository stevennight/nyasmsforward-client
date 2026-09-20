import 'package:client/src/api/api_client.dart';
import 'package:client/src/api/models.dart';
import 'package:client/src/notifications/notification_content.dart';
import 'package:client/src/notifications/notification_service.dart';
import 'package:client/src/pairing/token_store.dart';
import 'package:client/src/session/settings_store.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart' hide Message;
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_server.dart';

Message message({String peer = '106901234', String? code = '583921', String direction = 'in', int id = 42}) =>
    Message.fromJson({...msgJson(id, peer: peer, code: code, direction: direction), 'peerKey': peer.toLowerCase()});

class RecordingNotifier implements NotificationService {
  final outcomes = <String>[];

  @override
  Future<void> init() async {}
  @override
  Future<void> showMessage(Message m, {required bool canReply}) async {}
  @override
  Future<void> cancelMessages(Iterable<int> ids) async {}
  @override
  Future<void> showReplyOutcome(NotificationPayload to, {required String text}) async => outcomes.add(text);
}

void main() {
  group('content', () {
    test('a verification code leads the title, so it can be read from the lock screen', () {
      final c = contentFor(message());
      expect(c.title, '106901234 · 验证码 583921');
      expect(c.body, '你好');
      expect(contentFor(message(code: null)).title, '106901234');
    });

    test('the buttons offered depend on the code, the permission and the sender', () {
      expect(actionsFor(message(), canReply: true), ['copy', 'reply']);
      expect(actionsFor(message(), canReply: false), ['copy'], reason: 'no reply permission, no reply button');
      expect(actionsFor(message(code: null), canReply: true), ['reply']);
      expect(actionsFor(message(peer: 'ExampleBank', code: null), canReply: true), isEmpty, reason: 'named senders cannot be replied to');
      expect(actionsFor(message(peer: '+8613800000000', code: null), canReply: true), ['reply']);
    });

    test('the payload survives the trip through a notification, and garbage does not crash', () {
      final p = NotificationPayload.forMessage(message());
      final back = NotificationPayload.decode(p.encode())!;
      expect((back.messageId, back.deviceId, back.peer, back.code), (42, 'd1', '106901234', '583921'));
      expect(NotificationPayload.decode(null), isNull);
      expect(NotificationPayload.decode('not json'), isNull);
      expect(NotificationPayload.decode('{"x":1}'), isNull);
    });
  });

  group('what a notification does', () {
    late List<String> log;
    late RecordingNotifier notifier;
    late NotificationHandlers handlers;
    String? replyError;

    setUp(() {
      log = [];
      notifier = RecordingNotifier();
      replyError = null;
      handlers = NotificationHandlers(
        copyCode: (code) async => log.add('copy $code'),
        open: (to) => log.add('open ${to.deviceId}|${to.peerKey}'),
        reply: (to, text) async {
          log.add('reply ${to.messageId} $text');
          return replyError;
        },
      );
    });

    NotificationResponse response({String? action, String? input, Map<String, dynamic> data = const {}}) => NotificationResponse(
          notificationResponseType: action == null ? NotificationResponseType.selectedNotification : NotificationResponseType.selectedNotificationAction,
          actionId: action,
          input: input,
          data: data,
          payload: NotificationPayload.forMessage(message()).encode(),
        );

    test('the copy button copies the code', () async {
      await dispatchResponse(response(action: 'copy'), handlers, notifier);
      expect(log, ['copy 583921']);
    });

    test('tapping the notification opens the conversation', () async {
      await dispatchResponse(response(), handlers, notifier);
      expect(log, ['open d1|106901234']);
    });

    test('an inline reply (Android: input) is sent and the outcome replaces the notification', () async {
      await dispatchResponse(response(action: 'reply', input: '  TD  '), handlers, notifier);
      expect(log, ['reply 42 TD']);
      expect(notifier.outcomes, ['已回复：TD']);
    });

    test('an inline reply typed into a Windows toast arrives in the data map', () async {
      await dispatchResponse(response(action: 'reply', data: {'reply': '好的'}), handlers, notifier);
      expect(log, ['reply 42 好的']);
    });

    test('a failed reply says why, and an empty one sends nothing', () async {
      replyError = '发送太频繁，请稍后再试';
      await dispatchResponse(response(action: 'reply', input: 'TD'), handlers, notifier);
      expect(notifier.outcomes, ['回复失败：发送太频繁，请稍后再试']);
      log.clear();
      await dispatchResponse(response(action: 'reply', input: '   '), handlers, notifier);
      expect(log, isEmpty);
    });

    test('a notification without a usable payload does nothing', () async {
      await dispatchResponse(const NotificationResponse(notificationResponseType: NotificationResponseType.selectedNotification, actionId: 'copy'), handlers, notifier);
      expect(log, isEmpty);
    });
  });

  group('replying from a background isolate uses only stored data', () {
    test('it reads the token and address from storage and names the message', () async {
      final tokens = MemoryTokenStore()..write('nsf_tok');
      final settings = MemorySettingsStore(const ClientSettings(serverUrl: 'https://sms.example.com'));
      final server = FakeServer({'POST /api/v1/outbound': (_) => (201, taskJson())});
      final error = await replyFromStorage(42, 'TD', tokens: tokens, settings: settings, api: (url, token) => server.client(url, token));
      expect(error, isNull);
      final sent = server.called('POST', '/api/v1/outbound').single;
      expect(sent.body, {'replyToMessageId': 42, 'body': 'TD'});
      expect(sent.headers['Authorization'], 'Bearer nsf_tok');
      expect(sent.uri.origin, 'https://sms.example.com');
    });

    test('signed out: a clear message and nothing is sent', () async {
      final server = FakeServer();
      final error = await replyFromStorage(1, 'x', tokens: MemoryTokenStore(), settings: MemorySettingsStore(), api: (u, t) => server.client(u, t));
      expect(error, contains('还没有连接'));
      expect(server.calls, isEmpty);
    });

    test('a refusal from the server comes back in words', () async {
      final tokens = MemoryTokenStore()..write('nsf_tok');
      final settings = MemorySettingsStore(const ClientSettings(serverUrl: 'https://sms.example.com'));
      final server = FakeServer({'POST /api/v1/outbound': (_) => (403, {'error': 'policy_denied'})});
      final error = await replyFromStorage(1, 'x', tokens: tokens, settings: settings, api: (u, t) => server.client(u, t));
      expect(error, contains('下发策略不允许'));
    });
  });

  test('ApiException is what the reply path catches', () {
    expect(ApiException(kind: FailureKind.http, status: 403, code: 'scope_denied').text, contains('权限'));
  });
}
