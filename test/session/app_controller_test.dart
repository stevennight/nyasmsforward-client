import 'package:client/src/api/models.dart';
import 'package:client/src/pairing/connect_request.dart';
import 'package:client/src/pairing/token_store.dart';
import 'package:client/src/session/app_controller.dart';
import 'package:client/src/session/settings_store.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_server.dart';

void main() {
  late FakeServer server;
  late MemoryTokenStore tokens;
  late MemorySettingsStore store;
  late List<Message> alerts;
  late AppController controller;

  Future<void> until(bool Function() cond, {String? why}) async {
    for (var i = 0; i < 400 && !cond(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(cond(), isTrue, reason: why);
  }

  AppController build() => AppController(
        tokens: tokens,
        settingsStore: store,
        appVersion: '0.2.0',
        platform: 'windows',
        apiFactory: server.factory,
        onIncoming: alerts.add,
        pause: (_) async {}, // no real backoff waiting
      );

  final incoming = msgJson(2, code: '583921');

  setUp(() {
    server = FakeServer();
    tokens = MemoryTokenStore();
    store = MemorySettingsStore();
    alerts = [];
    controller = build();
  });

  tearDown(() => controller.dispose());

  group('starting', () {
    test('nothing stored: the connect screen', () async {
      await controller.start();
      expect(controller.phase, AppPhase.needsConnect);
    });

    test('a stored token is checked, the lists load and the stream opens', () async {
      await tokens.write('nsf_tok');
      store.value = const ClientSettings(serverUrl: 'https://sms.example.com', deviceName: '台式机');
      server.routes.addAll(connectedRoutes(conversations: [convJson(incoming, unread: 1)]));

      await controller.start();
      expect(controller.phase, AppPhase.ready);
      expect(controller.conversations.single.peer, '106901234');
      expect(controller.unread, 1);
      expect(controller.phones.single.name, contains('Pixel 7'));
      expect(controller.scopes.canSend, isTrue);
      expect(store.value.deviceId, 'c1', reason: 'the identity is remembered');
      await until(() => server.openStreams.length == 1);
      await until(() => controller.link == LinkState.live);
    });

    test('offline at launch: the app still opens and the token is kept', () async {
      await tokens.write('nsf_tok');
      store.value = const ClientSettings(serverUrl: 'https://sms.example.com', scopes: {'read'});
      server.routes['GET /api/v1/me'] = (_) => (503, '');
      server.routes['GET /api/v1/conversations'] = (_) => (503, '');
      server.routes['GET /api/v1/phones'] = (_) => (503, '');

      await controller.start();
      expect(controller.phase, AppPhase.ready);
      expect(controller.banner, contains('暂时不可用'));
      expect(await tokens.read(), 'nsf_tok');
      await until(() => server.openStreams.isNotEmpty || server.streamRequests.isNotEmpty, why: 'it keeps trying to connect');
    });

    test('a revoked token goes back to the connect screen, keeps the address and says why', () async {
      await tokens.write('nsf_old');
      store.value = const ClientSettings(serverUrl: 'https://sms.example.com', deviceName: '台式机', deviceId: 'c1', scopes: {'read'});
      server.routes['GET /api/v1/me'] = (_) => (401, {'error': 'token_revoked'});

      await controller.start();
      expect(controller.phase, AppPhase.needsConnect);
      expect(controller.banner, contains('已失效'));
      expect(await tokens.read(), isNull);
      expect(store.value.serverUrl, 'https://sms.example.com', reason: 'the address survives sign-out');
      expect(store.value.deviceName, '台式机');
      expect(store.value.deviceId, isNull);
    });

    test('a bare 401 from a proxy at launch does NOT sign out', () async {
      await tokens.write('nsf_tok');
      store.value = const ClientSettings(serverUrl: 'https://sms.example.com', scopes: {'read'});
      server.routes['GET /api/v1/me'] = (_) => (401, '<html>proxy auth</html>');
      server.routes['GET /api/v1/conversations'] = (_) => (401, '<html>proxy auth</html>');
      server.routes['GET /api/v1/phones'] = (_) => (401, '<html>proxy auth</html>');

      await controller.start();
      expect(controller.phase, AppPhase.ready);
      expect(await tokens.read(), 'nsf_tok');
      expect(controller.banner, contains('地址'));
    });

    test('without the read permission nothing is streamed and the reason is shown', () async {
      await tokens.write('nsf_tok');
      store.value = const ClientSettings(serverUrl: 'https://sms.example.com');
      server.routes.addAll(connectedRoutes(scopes: ['reply']));
      await controller.start();
      expect(controller.link, LinkState.noReadPermission);
      expect(controller.banner, contains('查看'));
      expect(server.streamRequests, isEmpty);
    });
  });

  group('connecting', () {
    test('a pairing code becomes a stored token and a live app', () async {
      server.routes.addAll(connectedRoutes());
      server.routes['POST /api/v1/pair/claim'] = (_) => {'deviceId': 'c1', 'token': 'nsf_new', 'scopes': ['read', 'reply', 'send']};
      await controller.start();
      expect(controller.phase, AppPhase.needsConnect);

      final error = await controller.connect(const ConnectRequest(serverUrl: 'https://sms.example.com', mode: ConnectMode.pairingCode, deviceName: '台式机', pairingCode: '483920'));
      expect(error, isNull);
      expect(controller.phase, AppPhase.ready);
      expect(await tokens.read(), 'nsf_new');
      expect(store.value.serverUrl, 'https://sms.example.com');
      expect(store.value.scopes, {'read', 'reply', 'send'});
      expect(server.called('POST', '/api/v1/pair/claim').single.body, containsPair('platform', 'windows'));
      expect(server.called('GET', '/api/v1/me').single.headers['Authorization'], 'Bearer nsf_new');
    });

    test('account login works the same way, and the password is not kept anywhere', () async {
      server.routes.addAll(connectedRoutes());
      server.routes['POST /api/v1/auth/login-device'] = (_) => {'deviceId': 'c1', 'token': 'nsf_new', 'scopes': ['read']};
      await controller.start();
      final error = await controller.connect(const ConnectRequest(
          serverUrl: 'https://sms.example.com', mode: ConnectMode.accountLogin, deviceName: '台式机', password: 'correct horse battery'));
      expect(error, isNull);
      expect(await tokens.read(), 'nsf_new');
      expect(store.value.toJson().toString(), isNot(contains('correct horse')));
    });

    test('a wrong code is refused with words and nothing is stored', () async {
      server.routes['POST /api/v1/pair/claim'] = (_) => (400, {'error': 'invalid_pair_code'});
      await controller.start();
      final error = await controller.connect(const ConnectRequest(serverUrl: 'https://sms.example.com', mode: ConnectMode.pairingCode, deviceName: 'x', pairingCode: '000000'));
      expect(error, contains('配对码'));
      expect(controller.phase, AppPhase.needsConnect);
      expect(await tokens.read(), isNull);
    });

    test('the receiver phone code is refused with an explanation', () async {
      server.routes['POST /api/v1/pair/claim'] = (_) => (400, {'error': 'pair_kind_mismatch'});
      await controller.start();
      final error = await controller.connect(const ConnectRequest(serverUrl: 'https://sms.example.com', mode: ConnectMode.pairingCode, deviceName: 'x', pairingCode: '123456'));
      expect(error, contains('接收端'));
    });

    test('signing out clears the token but keeps the address', () async {
      await tokens.write('nsf_tok');
      store.value = const ClientSettings(serverUrl: 'https://sms.example.com', deviceName: 'PC');
      server.routes.addAll(connectedRoutes());
      await controller.start();
      await controller.signOut();
      expect(controller.phase, AppPhase.needsConnect);
      expect(await tokens.read(), isNull);
      expect(store.value.serverUrl, 'https://sms.example.com');
      expect(controller.conversations, isEmpty);
    });
  });

  group('live', () {
    Future<void> connected({List<Map<String, Object?>>? conversations, Map<String, Object? Function(Req)>? extra}) async {
      await tokens.write('nsf_tok');
      store.value = const ClientSettings(serverUrl: 'https://sms.example.com');
      server.routes.addAll(connectedRoutes(conversations: conversations ?? [convJson(incoming, unread: 1)], messages: [incoming]));
      server.routes.addAll(extra ?? {});
      await controller.start();
      await until(() => server.openStreams.length == 1);
    }

    test('a message the server says to alert about alerts once and refreshes the lists', () async {
      await connected();
      var listings = server.called('GET', '/api/v1/conversations').length;
      server.emit('message', {...msgJson(3, body: '新短信'), 'notify': true}, id: 3);
      await until(() => alerts.length == 1);
      expect(alerts.single.id, 3);
      await until(() => server.called('GET', '/api/v1/conversations').length > listings, why: 'the list is refetched');

      listings = server.called('GET', '/api/v1/conversations').length;
      server.emit('message', {...msgJson(4, direction: 'out', origin: 'platform'), 'notify': false}, id: 4);
      await until(() => server.called('GET', '/api/v1/conversations').length > listings);
      expect(alerts, hasLength(1), reason: 'replies we sent and history never alert');
    });

    test('a fresh connection refetches what happened before it existed', () async {
      await connected();
      final before = server.called('GET', '/api/v1/conversations').length;
      await server.dropStream();
      await until(() => server.openStreams.length == 2);
      await until(() => server.called('GET', '/api/v1/conversations').length > before);
    });

    test('a phone coming or going updates its state in place', () async {
      await connected();
      expect(controller.phoneFor('d1')!.online, isTrue);
      server.emit('device', {'deviceId': 'd1', 'online': false});
      await until(() => !controller.phoneFor('d1')!.online);
    });

    test('a revoked token seen on the stream signs the client out', () async {
      await connected();
      server.routes['GET /api/v1/me'] = (_) => (401, {'error': 'token_revoked'});
      server.streamFailure = (status: 401, body: '{"error":"token_revoked"}');
      await server.dropStream();
      await until(() => controller.phase == AppPhase.needsConnect);
      expect(await tokens.read(), isNull);
    });

    test('opening a conversation loads it, marks it read and shows its send tasks', () async {
      await connected(extra: {
        'GET /api/v1/outbound': (_) => {'items': [taskJson(status: 'sent')]},
      });
      await controller.openConversation(controller.conversations.single);
      expect(controller.thread.single.code, '583921');
      expect(controller.tasks.single.status, TaskStatus.sent);
      final read = server.called('POST', '/api/v1/messages/read').last.body as Map;
      expect(read, {'deviceId': 'd1', 'peer': '106901234'});
      expect(controller.thread.single.isUnread, isFalse);
    });
  });

  group('sending', () {
    Future<void> open({List<String> scopes = const ['read', 'reply', 'send'], Map<String, Object?> phone = const {}, bool replyable = true}) async {
      await tokens.write('nsf_tok');
      store.value = const ClientSettings(serverUrl: 'https://sms.example.com');
      server.routes.addAll(connectedRoutes(
        scopes: scopes,
        conversations: [convJson(incoming, replyable: replyable)],
        messages: [incoming],
        phones: [{...phoneJson(), ...phone}],
      ));
      await controller.start();
      await controller.openConversation(controller.conversations.single);
    }

    test('a reply names the latest received message', () async {
      await open();
      server.routes['POST /api/v1/outbound'] = (_) => (201, taskJson());
      expect(controller.replyBlockedReason, isNull);
      expect(await controller.sendReply('TD'), isNull);
      expect(server.called('POST', '/api/v1/outbound').single.body, {'replyToMessageId': 2, 'body': 'TD'});
    });

    test('why a reply is not possible, most fundamental reason first', () async {
      await open(scopes: ['read'], phone: {'effectivePolicy': 'off'});
      expect(controller.replyBlockedReason, contains('没有“回复”权限'));
    });

    test('the phone policy blocks replying, and says whose policy it is', () async {
      await open(phone: {'effectivePolicy': 'off', 'sendPolicy': 'reply', 'phoneSendPolicy': 'off'});
      expect(controller.replyBlockedReason, '下发策略不允许回复（平台：仅回复；手机：关闭）');
    });

    test('alphanumeric senders cannot be replied to', () async {
      await open(replyable: false);
      expect(controller.replyBlockedReason, contains('字母'));
    });

    test('a refused send comes back as words and does not sign anyone out', () async {
      await open();
      server.routes['POST /api/v1/outbound'] = (_) => (429, {'error': 'rate_limited'});
      expect(await controller.sendReply('TD'), contains('太频繁'));
      expect(controller.phase, AppPhase.ready);
    });

    test('a new message goes through the chosen phone and SIM', () async {
      await open();
      server.routes['POST /api/v1/outbound'] = (_) => (201, taskJson(mode: 'new'));
      expect(await controller.sendNew(deviceId: 'd1', simSlot: 2, to: '13900000000', body: '你好'), isNull);
      expect(server.called('POST', '/api/v1/outbound').single.body, {'deviceId': 'd1', 'simSlot': 2, 'to': '13900000000', 'body': '你好'});
    });

    test('a task that has not reached the phone can be cancelled', () async {
      await open();
      server.routes['POST /api/v1/outbound/t_1/cancel'] = (_) => taskJson(status: 'failed', error: 'cancelled');
      expect(await controller.cancelTask('t_1'), isNull);
      server.routes['POST /api/v1/outbound/t_2/cancel'] = (_) => (409, {'error': 'not_cancellable'});
      expect(await controller.cancelTask('t_2'), contains('无法取消'));
    });
  });

  group('settings', () {
    setUp(() async {
      await tokens.write('nsf_tok');
      store.value = const ClientSettings(serverUrl: 'https://sms.example.com', deviceId: 'c1', scopes: {'read'});
      server.routes.addAll(connectedRoutes());
      await controller.start();
    });

    test('a new address is only saved when that server knows this device', () async {
      // Same device answers: saved, no re-login.
      expect(await controller.changeServerUrl('https://sms2.example.com/'), isNull);
      expect(store.value.serverUrl, 'https://sms2.example.com');
      expect(await tokens.read(), 'nsf_tok', reason: 'the token does not depend on the address');
    });

    test('an address of a different server, a typo, and a public http address are refused without saving', () async {
      server.routes['GET /api/v1/me'] = (_) => {'deviceId': 'someone-else', 'kind': 'client', 'name': 'x', 'scopes': ['read']};
      expect(await controller.changeServerUrl('https://other.example.com'), contains('不认识'));
      expect(await controller.changeServerUrl('http://public.example.com'), contains('HTTPS'));
      expect(await controller.changeServerUrl(''), contains('服务器地址'));
      expect(store.value.serverUrl, 'https://sms.example.com');
    });

    test('an address where the token is rejected explicitly is refused with a re-connect hint', () async {
      server.routes['GET /api/v1/me'] = (_) => (401, {'error': 'token_invalid'});
      expect(await controller.changeServerUrl('https://other.example.com'), contains('重新连接'));
      expect(controller.phase, AppPhase.ready, reason: 'a probe of the wrong server must not sign us out of the right one');
    });

    test('the connection test reports in words', () async {
      expect(await controller.testConnection(), contains('连接正常'));
      server.routes['GET /api/v1/me'] = (_) => (502, '');
      expect(await controller.testConnection(), contains('暂时不可用'));
    });

    test('settings survive being saved and loaded, including quick replies', () async {
      await controller.updateSettings(controller.settings.copyWith(quickReplies: ['好的', 'TD'], notifications: false));
      final loaded = await store.load();
      expect(loaded.quickReplies, ['好的', 'TD']);
      expect(loaded.notifications, isFalse);
      expect(ClientSettings.fromJson(loaded.toJson()).quickReplies, ['好的', 'TD']);
    });
  });
}
