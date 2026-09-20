@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:client/src/api/models.dart';
import 'package:client/src/pairing/connect_request.dart';
import 'package:client/src/pairing/token_store.dart';
import 'package:client/src/session/app_controller.dart';
import 'package:client/src/session/settings_store.dart';
import 'package:flutter_test/flutter_test.dart';

/// The client against a REAL server: pairing with a code, the live event stream, reading, replying through a stand-in
/// receiver phone, new messages, revocation. Skipped unless NYASMS_E2E_URL is set:
///
///   NYASMS_LISTEN=127.0.0.1:18080 NYASMS_DATA=(an empty dir) go run ./cmd/server        # in nyasmsforward-server
///   $env:NYASMS_E2E_URL = "http://127.0.0.1:18080"; flutter test test/e2e (from the client directory)
final _base = Platform.environment['NYASMS_E2E_URL']?.replaceFirst(RegExp(r'/+$'), '');

class Admin {
  final _http = HttpClient();
  String cookie = '';

  Future<(int, Map<String, Object?>)> call(String method, String path, [Object? body]) async {
    final req = await _http.openUrl(method, Uri.parse('$_base$path'));
    req.headers.set('X-NyaSms-CSRF', '1');
    if (cookie.isNotEmpty) req.headers.set('Cookie', cookie);
    if (body != null) {
      req.headers.contentType = ContentType.json;
      req.add(utf8.encode(jsonEncode(body)));
    }
    final res = await req.close();
    for (final c in res.headers[HttpHeaders.setCookieHeader] ?? const <String>[]) {
      if (c.startsWith('nyasms_session=')) cookie = c.split(';').first;
    }
    final text = await res.transform(utf8.decoder).join();
    return (res.statusCode, text.isEmpty ? <String, Object?>{} : (jsonDecode(text) as Map).cast<String, Object?>());
  }

  Future<void> ensure() async {
    final (status, _) = await call('POST', '/api/auth/setup', {'password': 'e2e-test-password-123'});
    if (status == 409) {
      expect((await call('POST', '/api/auth/login', {'password': 'e2e-test-password-123'})).$1, 200);
    } else {
      expect(status, 201);
    }
  }

  Future<String> pairingCode(Map<String, Object?> body) async => (await call('POST', '/api/v1/pairings', body)).$2['code']! as String;
}

/// A receiver phone: pairs, keeps the WebSocket open, and answers every send task with sent then delivered.
class StandInPhone {
  StandInPhone(this.token, this.deviceId);

  final String token;
  final String deviceId;
  late WebSocket _ws;
  final frames = <Map<String, Object?>>[];

  static Future<StandInPhone> pair(Admin admin) async {
    final code = await admin.pairingCode({'kind': 'phone'});
    final client = HttpClient();
    final req = await client.postUrl(Uri.parse('$_base/api/v1/pair/claim'));
    req.headers.contentType = ContentType.json;
    req.add(utf8.encode(jsonEncode({
      'code': code, 'name': 'Stand-in', 'kind': 'phone', 'platform': 'android',
      'sims': [{'slot': 1, 'subscriptionId': 3, 'label': 'A'}],
    })));
    final out = jsonDecode(await (await req.close()).transform(utf8.decoder).join()) as Map;
    return StandInPhone(out['token'] as String, out['deviceId'] as String);
  }

  Future<void> upload(int n, String peer, String body) async {
    final client = HttpClient();
    final req = await client.postUrl(Uri.parse('$_base/api/v1/device/messages'));
    req.headers.contentType = ContentType.json;
    req.headers.set('Authorization', 'Bearer $token');
    req.add(utf8.encode(jsonEncode({
      'messages': [
        {'dedupeKey': 'sha256:${n.toRadixString(16).padLeft(64, '0')}', 'direction': 'in', 'peer': peer, 'body': body, 'simSlot': 1, 'deviceTime': DateTime.now().millisecondsSinceEpoch},
      ],
    })));
    expect((await req.close()).statusCode, 200);
  }

  Future<void> connect(String policy) async {
    _ws = await WebSocket.connect('${_base!.replaceFirst('http', 'ws')}/api/v1/device/ws', headers: {'Authorization': 'Bearer $token'});
    _ws.add(jsonEncode({'type': 'hello', 'appVersion': 'e2e', 'battery': 90, 'sendPolicy': policy, 'sims': [{'slot': 1, 'subscriptionId': 3, 'label': 'A'}]}));
    _ws.listen((data) {
      final f = (jsonDecode(data as String) as Map).cast<String, Object?>();
      frames.add(f);
      if (f['type'] == 'send_sms') {
        Future<void>.delayed(const Duration(milliseconds: 50), () => _ws.add(jsonEncode({'type': 'send_result', 'taskId': f['taskId'], 'status': 'sent'})));
        Future<void>.delayed(const Duration(milliseconds: 150), () => _ws.add(jsonEncode({'type': 'send_result', 'taskId': f['taskId'], 'status': 'delivered'})));
      }
    });
  }

  Future<void> close() => _ws.close();
}

Future<void> eventually(String what, bool Function() check, {Duration timeout = const Duration(seconds: 15)}) async {
  final end = DateTime.now().add(timeout);
  while (!check()) {
    if (DateTime.now().isAfter(end)) fail('timed out waiting for: $what');
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
}

void main() {
  test('pair, stream, read, reply, send new and get revoked against the real server', () async {
    final admin = Admin();
    await admin.ensure();

    // A receiver phone that has received one message and allows replies.
    final phone = await StandInPhone.pair(admin);
    await phone.upload(1, '+86 138 0000 0000', '验证码 583921，5 分钟内有效');
    await admin.call('PATCH', '/api/v1/devices/${phone.deviceId}', {'sendPolicy': 'reply'});
    await phone.connect('reply');

    // The client connects with a pairing code typed the way the console shows it.
    final alerts = <Message>[];
    final tokens = MemoryTokenStore();
    final store = MemorySettingsStore();
    final controller = AppController(
      tokens: tokens,
      settingsStore: store,
      appVersion: '0.2.0',
      platform: 'windows',
      onIncoming: alerts.add,
    );
    addTearDown(controller.dispose);
    await controller.start();
    expect(controller.phase, AppPhase.needsConnect);

    final code = await admin.pairingCode({'kind': 'client'});
    final error = await controller.connect(ConnectRequest(serverUrl: _base!, mode: ConnectMode.pairingCode, deviceName: 'E2E 客户端', pairingCode: '${code.substring(0, 3)}${code.substring(3)}'));
    expect(error, isNull);
    expect(controller.phase, AppPhase.ready);
    expect(controller.scopes.canSend, isTrue);
    expect((await tokens.read())!, startsWith('nsf_'));

    // Reading: the conversation, its verification code, and the phone with its live state.
    await eventually('the conversation shows up', () => controller.conversations.isNotEmpty);
    final conv = controller.conversations.single;
    expect(conv.peerKey, '13800000000');
    expect(conv.last.code, '583921');
    await eventually('the stream is live', () => controller.link == LinkState.live);
    await eventually('the phone is online', () => controller.phones.isNotEmpty && controller.phones.first.online);
    expect(controller.phones.first.effectivePolicy.name, 'reply');

    await controller.openConversation(conv);
    expect(controller.thread.single.body, contains('验证码'));
    await eventually('opening the thread marked it read', () => controller.unread == 0);

    // Live: a new SMS arrives through the phone and the client hears about it on the stream, once, with notify.
    await phone.upload(2, '+86 138 0000 0000', '第二条');
    await eventually('the live message alerts', () => alerts.isNotEmpty);
    expect(alerts.single.body, '第二条');
    await eventually('the thread refreshes', () => controller.thread.length == 2);

    // Reply: names the latest received message, goes to the phone on the original SIM, and comes back as a delivered task.
    expect(controller.replyBlockedReason, isNull);
    expect(await controller.sendReply('TD'), isNull);
    await eventually('the phone got the task', () => phone.frames.any((f) => f['type'] == 'send_sms'));
    final frame = phone.frames.firstWhere((f) => f['type'] == 'send_sms');
    expect(frame['mode'], 'reply');
    expect(frame['to'], '+8613800000000');
    expect(frame['simSlot'], 1);
    await eventually('the task is delivered', () => controller.tasks.isNotEmpty && controller.tasks.first.status == TaskStatus.delivered);
    await eventually('the reply shows in the thread', () => controller.thread.any((m) => !m.isIncoming && m.body == 'TD'));
    expect(controller.thread.last.origin, 'platform');
    expect(alerts, hasLength(1), reason: 'a reply we sent ourselves never alerts');

    // New messages are refused while either side says "reply only".
    expect(await controller.sendNew(deviceId: phone.deviceId, to: '13900000000', body: 'hi'), contains('下发策略不允许'));

    // Revoking the client's token signs it out through the stream (kept: address and name).
    final me = await admin.call('GET', '/api/v1/devices');
    final clientId = (me.$2['items']! as List).cast<Map>().firstWhere((d) => d['kind'] == 'client' && d['name'] == 'E2E 客户端')['id'];
    expect((await admin.call('DELETE', '/api/v1/devices/$clientId')).$1, 204);
    await eventually('the client is signed out', () => controller.phase == AppPhase.needsConnect);
    expect(await tokens.read(), isNull);
    expect(store.value.serverUrl, _base);
    expect(controller.banner, contains('已失效'));

    await phone.close();
  }, skip: _base == null ? 'set NYASMS_E2E_URL to run' : false);
}
