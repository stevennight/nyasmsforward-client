import 'dart:async';

import 'package:client/src/api/api_client.dart';
import 'package:client/src/api/connection.dart';
import 'package:client/src/api/models.dart';
import 'package:client/src/api/protocol.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import '../support/fake_server.dart';

void main() {
  group('pairing', () {
    test(
      'claim sends the code as a client, and the token comes back as a result',
      () async {
        final server = FakeServer({
          'POST /api/v1/pair/claim': (_) => {
            'deviceId': 'd_c',
            'token': 'nsf_abc',
            'scopes': ['read', 'reply'],
            'kind': 'client',
          },
        });
        final result = await server
            .client('https://sms.example.com/', null)
            .claim(
              code: '483920',
              name: 'Pixel 9',
              platform: 'android',
              appVersion: '0.2.0',
            );
        expect(result.token, 'nsf_abc');
        expect(result.scopes, {'read', 'reply'});
        final sent = server.called('POST', '/api/v1/pair/claim').single;
        expect(sent.body, {
          'code': '483920',
          'name': 'Pixel 9',
          'kind': 'client',
          'platform': 'android',
          'appVersion': '0.2.0',
        });
        expect(
          sent.uri.origin,
          'https://sms.example.com',
          reason: 'a trailing slash on the address must not double up',
        );
        expect(sent.headers.containsKey('Authorization'), isFalse);
      },
    );

    test('account login sends the password once, in the body, and never a token in the URL', () async {
      final server = FakeServer({
        'POST /api/v1/auth/login-device': (_) => {
          'deviceId': 'd_c',
          'token': 'nsf_xyz',
          'scopes': ['read'],
        },
      });
      await server
          .client('https://sms.example.com', null)
          .loginDevice(
            password: 'hunter2 hunter2',
            name: 'PC',
            platform: 'windows',
            appVersion: '0.2.0',
          );
      final sent = server.called('POST', '/api/v1/auth/login-device').single;
      expect((sent.body as Map)['password'], 'hunter2 hunter2');
      expect(sent.uri.query, isEmpty);
    });

    test('server refusals carry their code and read in words', () async {
      for (final (code, text) in [
        ('invalid_pair_code', '配对码错误'),
        ('pair_kind_mismatch', '接收端的配对码'),
        ('invalid_credentials', '密码不正确'),
        ('too_many_attempts', '尝试次数太多'),
      ]) {
        final server = FakeServer({
          'POST /api/v1/pair/claim': (_) => (400, {'error': code}),
        });
        await expectLater(
          server
              .client('https://x.example', null)
              .claim(
                code: '1',
                name: 'n',
                platform: 'android',
                appVersion: '1',
              ),
          throwsA(
            isA<ApiException>()
                .having((e) => e.code, 'code', code)
                .having((e) => e.text, 'text', contains(text)),
          ),
        );
      }
    });
  });

  group('every request carries the token in the header only', () {
    test('GET with query parameters', () async {
      final server = FakeServer(connectedRoutes());
      final api = server.client('https://sms.example.com', 'nsf_secret');
      await api.conversations(query: '验证码', unreadOnly: true);
      await api.thread('d1', '13800000000');
      final calls = server.calls;
      expect(
        calls.every((c) => c.headers['Authorization'] == 'Bearer nsf_secret'),
        isTrue,
      );
      expect(
        calls.every((c) => !c.uri.toString().contains('nsf_secret')),
        isTrue,
      );
      expect(calls.first.uri.queryParameters, {
        'q': '验证码',
        'unread': '1',
        'limit': '200',
      });
      expect(calls.last.uri.queryParameters, {
        'device': 'd1',
        'peer': '13800000000',
        'limit': '200',
      });
    });
  });

  group('reading', () {
    test(
      'conversations and threads parse, threads come back oldest first',
      () async {
        final server = FakeServer(
          connectedRoutes(
            conversations: [convJson(msgJson(2, code: '583921'), unread: 1)],
            messages: [
              msgJson(3, direction: 'out', origin: 'platform', replyTo: 2),
              msgJson(2, code: '583921'),
            ],
          ),
        );
        final api = server.client('https://x.example', 't');
        final list = await api.conversations();
        expect(list.unread, 1);
        expect(list.items.single.last.code, '583921');
        expect(list.items.single.replyable, isTrue);
        final thread = await api.thread('d1', '106901234');
        expect(thread.map((m) => m.id), [2, 3]);
        expect(thread.last.isIncoming, isFalse);
        expect(thread.last.replyTo, 2);
      },
    );

    test('complete conversation deletion sends device or SIM-card identity for every selected group', () async {
      final server = FakeServer({
        'POST /api/v1/messages/delete-conversations': (_) => {'deleted': 8},
      });
      final api = server.client('https://x.example', 't');
      final deviceConversation = Conversation.fromJson(
        convJson(msgJson(2, peer: '106901234')),
      );
      final cardConversation = Conversation.fromJson({
        ...convJson(msgJson(3, peer: '13800000000')),
        'cardNumber': '13800138000',
      });

      expect(
        await api.deleteConversations([deviceConversation, cardConversation]),
        8,
      );
      expect(server.calls.single.body, {
        'conversations': [
          {'peerKey': '106901234', 'deviceId': 'd1'},
          {'peerKey': '13800000000', 'cardNumber': '13800138000'},
        ],
      });
    });

    test(
      'phones parse with their effective policy and reasons for being blocked',
      () async {
        final server = FakeServer(
          connectedRoutes(
            phones: [
              phoneJson(effective: 'off', platform: 'reply', phonePolicy: null),
            ],
          ),
        );
        final phone =
            (await server.client('https://x.example', 't').phones()).single;
        expect(phone.effectivePolicy, SendPolicy.off);
        expect(phone.blockedReason(reply: true), contains('平台：仅回复；手机：手机尚未上报'));
        expect(phone.sims.map((s) => s.title), ['SIM1 · 中国移动', 'SIM2 · 中国联通']);
      },
    );

    test('unknown fields and missing optional ones do not break parsing', () {
      final m = Message.fromJson({
        'id': 1,
        'direction': 'in',
        'futureField': [1, 2, 3],
      });
      expect(m.id, 1);
      expect(m.peer, '');
      expect(m.code, isNull);
      expect(
        ServerEvent.parse('from_the_future', {'a': 1}),
        isA<UnknownEvent>(),
      );
    });
  });

  group('sending', () {
    test('a reply names the message and nothing else', () async {
      final server = FakeServer({
        'POST /api/v1/outbound': (_) => (201, taskJson()),
      });
      final task = await server.client('https://x.example', 't').reply(2, 'TD');
      expect(task.status, TaskStatus.queued);
      expect(server.calls.single.body, {'replyToMessageId': 2, 'body': 'TD'});
    });

    test('a new message names the phone, the SIM and the number', () async {
      final server = FakeServer({
        'POST /api/v1/outbound': (_) => (201, taskJson(mode: 'new')),
      });
      final api = server.client('https://x.example', 't');
      await api.sendNew(
        deviceId: 'd1',
        simSlot: 2,
        to: '139 0000 0000',
        body: '你好',
      );
      await api.sendNew(deviceId: 'd1', to: '13900000000', body: 'x');
      expect(server.calls.first.body, {
        'deviceId': 'd1',
        'simSlot': 2,
        'to': '139 0000 0000',
        'body': '你好',
      });
      expect(
        (server.calls.last.body as Map).containsKey('simSlot'),
        isFalse,
        reason: 'no slot means the default SIM',
      );
    });

    test('task summaries use the words of the web console', () {
      expect(
        OutboundTask.fromJson(
          taskJson(status: 'failed', error: 'recipient_not_recent'),
        ).summary,
        '失败：收件人不在手机的“最近来信号码”里',
      );
      expect(
        OutboundTask.fromJson(taskJson(status: 'queued')).summary,
        '排队中（等待手机上线）',
      );
      expect(
        OutboundTask.fromJson(taskJson(status: 'delivered')).summary,
        '已送达',
      );
      expect(
        OutboundTask.fromJson(
          taskJson(status: 'failed', error: 'something_new'),
        ).summary,
        '失败：something_new',
      );
    });

    test('policy and scope refusals read in words', () async {
      for (final (status, code, text) in [
        (403, 'policy_denied', '下发策略不允许'),
        (403, 'scope_denied', '没有该操作的权限'),
        (422, 'reply_not_supported', '字母'),
        (429, 'rate_limited', '太频繁'),
      ]) {
        final server = FakeServer({
          'POST /api/v1/outbound': (_) => (status, {'error': code}),
        });
        await expectLater(
          server.client('https://x.example', 't').reply(1, 'x'),
          throwsA(
            isA<ApiException>()
                .having((e) => e.text, 'text', contains(text))
                .having((e) => e.isTokenDead, 'dead', isFalse),
          ),
        );
      }
    });
  });

  group('what a failure means for the token (docs/协议.md §2.2)', () {
    Future<ApiException> failure(FakeServer s) async {
      try {
        await s.client('https://x.example', 't').me();
      } on ApiException catch (e) {
        return e;
      }
      fail('expected a failure');
    }

    test('401 with a token error code means the token is dead', () async {
      for (final code in ['token_revoked', 'token_invalid', 'token_expired']) {
        final e = await failure(
          FakeServer({
            'GET /api/v1/me': (_) => (401, {'error': code}),
          }),
        );
        expect(e.verdict, ConnectionVerdict.needsPairing, reason: code);
        expect(e.isTokenDead, isTrue);
      }
    });

    test('a bare 401 (proxy auth), 403 and 404 keep the token and suspect the address', () async {
      for (final status in [401, 403, 404]) {
        final e = await failure(
          FakeServer({
            'GET /api/v1/me': (_) => (status, '<html>Basic auth</html>'),
          }),
        );
        expect(e.verdict, ConnectionVerdict.addressSuspect, reason: '$status');
        expect(e.isTokenDead, isFalse);
        expect(e.text, contains('地址'));
      }
    });

    test('5xx and 429 are transient', () async {
      for (final status in [429, 500, 502, 503, 504]) {
        final e = await failure(
          FakeServer({'GET /api/v1/me': (_) => (status, '')}),
        );
        expect(e.verdict, ConnectionVerdict.transient, reason: '$status');
      }
    });

    test('an answer that is not our JSON is "not our server", including a redirect', () async {
      var e = await failure(
        FakeServer({
          'GET /api/v1/me': (_) => '<html>welcome to the captive portal</html>',
        }),
      );
      expect(e.kind, FailureKind.notOurServer);
      e = await failure(FakeServer({'GET /api/v1/me': (_) => (302, '')}));
      expect(e.kind, FailureKind.notOurServer);
      expect(e.verdict, ConnectionVerdict.addressSuspect);
    });

    test('network errors and timeouts are transient and never say the token is dead', () async {
      final down = ApiClient(
        baseUrl: 'https://x.example',
        token: 't',
        httpClient: MockClient(
          (_) async => throw http.ClientException('connection refused'),
        ),
      );
      await expectLater(
        down.me(),
        throwsA(
          isA<ApiException>()
              .having((e) => e.kind, 'kind', FailureKind.network)
              .having((e) => e.verdict, 'verdict', ConnectionVerdict.transient),
        ),
      );

      final slow = ApiClient(
        baseUrl: 'https://x.example',
        token: 't',
        timeout: const Duration(milliseconds: 20),
        httpClient: MockClient((_) => Completer<http.Response>().future),
      );
      await expectLater(
        slow.me(),
        throwsA(
          isA<ApiException>().having(
            (e) => e.kind,
            'kind',
            FailureKind.timeout,
          ),
        ),
      );
    });
  });
}
