import 'package:client/src/app/app.dart';
import 'package:client/src/pairing/pair_link.dart';
import 'package:client/src/pairing/token_store.dart';
import 'package:client/src/session/app_controller.dart';
import 'package:client/src/session/platform_hooks.dart';
import 'package:client/src/session/settings_store.dart';
import 'package:client/src/ui/home_screen.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_server.dart';

class Rig {
  Rig({
    List<String> scopes = const ['read', 'reply', 'send'],
    Map<String, Object?> phone = const {},
    bool replyable = true,
    List<Map<String, Object?>>? extraConversations,
    this.connected = true,
    PlatformHooks hooks = const PlatformHooks(),
  }) {
    server = FakeServer(
      connectedRoutes(
        scopes: scopes,
        conversations: [
          convJson(
            msgJson(2, code: '583921', body: '【示例商城】验证码 583921'),
            unread: 1,
            replyable: replyable,
          ),
          ...?extraConversations,
        ],
        messages: [msgJson(2, code: '583921', body: '【示例商城】验证码 583921')],
        phones: [
          {...phoneJson(), ...phone},
        ],
      ),
    );
    tokens = MemoryTokenStore();
    store = MemorySettingsStore(
      connected
          ? const ClientSettings(
              serverUrl: 'https://sms.example.com',
              deviceName: '台式机',
            )
          : const ClientSettings(),
    );
    controller = AppController(
      tokens: tokens,
      settingsStore: store,
      appVersion: '0.2.0',
      platform: 'windows',
      apiFactory: server.factory,
      streamEnabled: false,
      hooks: hooks,
    );
  }

  final bool connected;
  late final FakeServer server;
  late final MemoryTokenStore tokens;
  late final MemorySettingsStore store;
  late final AppController controller;

  Future<void> pump(
    WidgetTester tester, {
    Size size = const Size(1200, 800),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    addTearDown(controller.dispose);
    if (connected) await tokens.write('nsf_tok');
    await tester.pumpWidget(NyaApp(controller: controller));
    await controller.start();
    await tester.pumpAndSettle();
  }
}

Finder byKey(String k) => find.byKey(Key(k));

class FakeLaunch implements LaunchAtLogin {
  bool enabled = false;
  @override
  Future<bool> isEnabled() async => enabled;
  @override
  Future<void> set(bool value) async => enabled = value;
}

class FakeBattery implements BatteryExemption {
  int requested = 0;
  @override
  Future<bool> isExempt() async => requested > 0;
  @override
  Future<void> request() async => requested++;
}

void main() {
  group('the app root', () {
    testWidgets(
      'without a stored connection it shows the connect form, with the remembered address after sign-out',
      (tester) async {
        final rig = Rig(connected: false);
        rig.store.value = const ClientSettings(
          serverUrl: 'https://sms.example.com',
          deviceName: '旧电脑',
        );
        await rig.pump(tester);
        expect(find.text('连接到服务器'), findsOneWidget);
        expect(
          tester.widget<TextField>(byKey('serverUrl')).controller!.text,
          'https://sms.example.com',
        );
        expect(
          tester.widget<TextField>(byKey('deviceName')).controller!.text,
          '旧电脑',
        );
      },
    );

    testWidgets('connecting through the form ends in the app', (tester) async {
      final rig = Rig(connected: false);
      rig.server.routes['POST /api/v1/pair/claim'] = (_) => {
        'deviceId': 'c1',
        'token': 'nsf_new',
        'scopes': ['read', 'reply', 'send'],
      };
      await rig.pump(tester);
      await tester.enterText(byKey('serverUrl'), 'https://sms.example.com');
      await tester.enterText(byKey('pairingCode'), '483 920');
      await tester.ensureVisible(byKey('connect'));
      await tester.tap(byKey('connect'));
      await tester.pumpAndSettle();
      expect(find.byType(AppBar), findsOneWidget);
      expect(find.text('106901234'), findsWidgets);
      expect(await rig.tokens.read(), 'nsf_new');
    });

    testWidgets('a refused pairing shows the reason under the form', (
      tester,
    ) async {
      final rig = Rig(connected: false);
      rig.server.routes['POST /api/v1/pair/claim'] = (_) =>
          (400, {'error': 'invalid_pair_code'});
      await rig.pump(tester);
      await tester.enterText(byKey('serverUrl'), 'https://sms.example.com');
      await tester.enterText(byKey('pairingCode'), '000000');
      await tester.ensureVisible(byKey('connect'));
      await tester.tap(byKey('connect'));
      await tester.pumpAndSettle();
      expect(find.textContaining('配对码错误'), findsOneWidget);
    });

    testWidgets('a pasted pairing link fills the address and the code', (
      tester,
    ) async {
      final rig = Rig(connected: false);
      await rig.pump(tester);
      await tester.enterText(
        byKey('serverUrl'),
        'nyasmsforward://pair?server=https%3A%2F%2Fsms.example.com&code=483920',
      );
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(byKey('serverUrl')).controller!.text,
        'https://sms.example.com',
      );
      expect(
        tester.widget<TextField>(byKey('pairingCode')).controller!.text,
        '483920',
      );
    });

    test('pairing links are parsed strictly', () {
      expect(
        PairLink.tryParse(
          'nyasmsforward://pair?server=https://sms.example.com&code=483920',
        )?.code,
        '483920',
      );
      expect(
        PairLink.tryParse(
          'nyasmsforward://pair?server=https%3A%2F%2Fsms.example.com&code=483%20920',
        )?.code,
        '483920',
      );
      expect(
        PairLink.tryParse('https://evil.example/pair?server=x&code=483920'),
        isNull,
      );
      expect(
        PairLink.tryParse(
          'nyasmsforward://pair?server=https://x.example&code=12',
        ),
        isNull,
      );
      expect(PairLink.tryParse('nyasmsforward://pair?code=483920'), isNull);
      expect(PairLink.tryParse('not a link'), isNull);
    });
  });

  group('conversations', () {
    testWidgets(
      'a wide window shows the list and the open conversation side by side, with the code card',
      (tester) async {
        final rig = Rig();
        await rig.pump(tester);
        expect(find.byKey(const Key('unreadBadge')), findsOneWidget);
        expect(find.text('选择一个会话查看内容'), findsOneWidget);

        await tester.tap(find.byType(ConversationTile).first);
        await tester.pumpAndSettle();
        expect(byKey('codeText'), findsOneWidget);
        expect(tester.widget<Text>(byKey('codeText')).data, '583921');
        expect(find.text('选择一个会话查看内容'), findsNothing);
        // Opening it read it.
        expect(rig.server.called('POST', '/api/v1/messages/read'), isNotEmpty);
      },
    );

    testWidgets('copying the verification code puts it on the clipboard', (
      tester,
    ) async {
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map)['text'] as String;
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      final rig = Rig();
      await rig.pump(tester);
      await tester.tap(find.byType(ConversationTile).first);
      await tester.pumpAndSettle();
      await tester.tap(byKey('copyCode'));
      await tester.pump(const Duration(milliseconds: 100));
      expect(copied, '583921');
      expect(find.text('已复制 ✓'), findsOneWidget);
      await tester.pump(const Duration(seconds: 2));
    });

    testWidgets(
      'on a phone the list and the conversation are separate pages and Back returns to the list',
      (tester) async {
        final rig = Rig();
        await rig.pump(tester, size: const Size(420, 800));
        expect(find.byKey(const Key('conversations')), findsOneWidget);
        await tester.tap(find.byType(ConversationTile).first);
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('conversations')), findsNothing);
        expect(byKey('replyField'), findsOneWidget);
        await tester.tap(find.byType(BackButton));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('conversations')), findsOneWidget);
      },
    );

    testWidgets('search narrows the list and an empty result is explained', (
      tester,
    ) async {
      final rig = Rig(
        extraConversations: [
          convJson(msgJson(9, peer: '13800000000', body: '你到家了吗？')),
        ],
      );
      await rig.pump(tester);
      expect(find.byType(ConversationTile), findsNWidgets(2));
      await tester.enterText(byKey('search'), '到家');
      await tester.pump();
      expect(find.byType(ConversationTile), findsOneWidget);
      await tester.enterText(byKey('search'), 'zzz');
      await tester.pump();
      expect(find.text('没有匹配的会话'), findsOneWidget);
    });

    testWidgets('selects multiple complete number conversations for deletion', (
      tester,
    ) async {
      final rig = Rig(
        scopes: const ['read', 'reply', 'send', 'delete'],
        extraConversations: [
          convJson(msgJson(9, peer: '13800000000', body: '你到家了吗？')),
        ],
      );
      rig.server.routes['POST /api/v1/messages/delete-conversations'] = (_) => {
        'deleted': 2,
      };
      await rig.pump(tester);

      await tester.tap(find.byTooltip('选择会话'));
      await tester.pump();
      expect(find.byType(Checkbox), findsNWidgets(2));
      await tester.tap(find.byType(ConversationTile).first);
      await tester.tap(find.byType(ConversationTile).at(1));
      await tester.pump();
      await tester.tap(byKey('deleteSelectedConversations'));
      await tester.pumpAndSettle();
      expect(find.text('删除选中的 2 个会话？'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, '删除'));
      await tester.pumpAndSettle();

      expect(
        rig.server
            .called('POST', '/api/v1/messages/delete-conversations')
            .single
            .body,
        {
          'conversations': [
            {'peerKey': '106901234', 'deviceId': 'd1'},
            {'peerKey': '13800000000', 'deviceId': 'd1'},
          ],
        },
      );
    });

    testWidgets(
      'connection trouble is shown above the list, and the live indicator says so',
      (tester) async {
        final rig = Rig();
        rig.server.routes['GET /api/v1/conversations'] = (_) => (503, '');
        await rig.pump(tester);
        expect(byKey('banner'), findsOneWidget);
        expect(find.textContaining('暂时不可用'), findsOneWidget);
      },
    );
  });

  group('replying', () {
    Future<void> openThread(WidgetTester tester) async {
      await tester.tap(find.byType(ConversationTile).first);
      await tester.pumpAndSettle();
    }

    testWidgets(
      'typing and sending posts the reply naming the message, then clears the box',
      (tester) async {
        final rig = Rig();
        rig.server.routes['POST /api/v1/outbound'] = (_) => (201, taskJson());
        await rig.pump(tester);
        await openThread(tester);
        await tester.enterText(byKey('replyField'), 'TD');
        await tester.pump();
        await tester.tap(byKey('sendReply'));
        await tester.pumpAndSettle();
        expect(rig.server.called('POST', '/api/v1/outbound').single.body, {
          'replyToMessageId': 2,
          'body': 'TD',
        });
        expect(
          tester.widget<TextField>(byKey('replyField')).controller!.text,
          isEmpty,
        );
      },
    );

    testWidgets('Enter sends, Shift+Enter does not', (tester) async {
      final rig = Rig();
      rig.server.routes['POST /api/v1/outbound'] = (_) => (201, taskJson());
      await rig.pump(tester);
      await openThread(tester);
      await tester.tap(byKey('replyField'));
      await tester.enterText(byKey('replyField'), '好的');
      await tester.pump();

      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pumpAndSettle();
      expect(rig.server.called('POST', '/api/v1/outbound'), isEmpty);

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(rig.server.called('POST', '/api/v1/outbound'), hasLength(1));
    });

    testWidgets('a quick reply fills the box and does not send by itself', (
      tester,
    ) async {
      final rig = Rig();
      await rig.pump(tester);
      await openThread(tester);
      await tester.tap(find.widgetWithText(ActionChip, 'TD'));
      await tester.pump();
      expect(
        tester.widget<TextField>(byKey('replyField')).controller!.text,
        'TD',
      );
      expect(rig.server.called('POST', '/api/v1/outbound'), isEmpty);
    });

    testWidgets('a refusal is shown and the text is kept for a retry', (
      tester,
    ) async {
      final rig = Rig();
      rig.server.routes['POST /api/v1/outbound'] = (_) =>
          (429, {'error': 'rate_limited'});
      await rig.pump(tester);
      await openThread(tester);
      await tester.enterText(byKey('replyField'), 'TD');
      await tester.pump();
      await tester.tap(byKey('sendReply'));
      await tester.pumpAndSettle();
      expect(find.textContaining('发送太频繁'), findsOneWidget);
      expect(
        tester.widget<TextField>(byKey('replyField')).controller!.text,
        'TD',
      );
    });

    testWidgets('the phone policy blocks the box and says whose policy it is', (
      tester,
    ) async {
      final rig = Rig(
        phone: {
          'effectivePolicy': 'off',
          'sendPolicy': 'reply',
          'phoneSendPolicy': 'off',
        },
      );
      await rig.pump(tester);
      await openThread(tester);
      expect(find.textContaining('平台：仅回复；手机：关闭'), findsOneWidget);
      expect(tester.widget<TextField>(byKey('replyField')).enabled, isFalse);
      expect(tester.widget<FilledButton>(byKey('sendReply')).onPressed, isNull);
    });

    testWidgets('a client without the reply permission cannot reply', (
      tester,
    ) async {
      final rig = Rig(scopes: ['read']);
      await rig.pump(tester);
      await openThread(tester);
      expect(find.textContaining('没有“回复”权限'), findsOneWidget);
    });

    testWidgets('alphanumeric senders cannot be replied to', (tester) async {
      final rig = Rig(replyable: false);
      await rig.pump(tester);
      await openThread(tester);
      expect(find.text('字母 / 名称发件人无法回复'), findsOneWidget);
    });

    testWidgets(
      'an offline phone is announced and the send tasks show how far they got, with cancel for queued ones',
      (tester) async {
        final rig = Rig(phone: {'online': false});
        rig.server.routes['GET /api/v1/outbound'] = (_) => {
          'items': [
            taskJson(id: 't_1'),
            taskJson(
              id: 't_2',
              body: 'Y',
              status: 'failed',
              error: 'recipient_not_recent',
            ),
          ],
        };
        rig.server.routes['POST /api/v1/outbound/t_1/cancel'] = (_) =>
            taskJson(id: 't_1', status: 'failed', error: 'cancelled');
        await rig.pump(tester);
        await openThread(tester);
        expect(find.textContaining('手机当前不在线'), findsOneWidget);
        expect(find.text('排队中（等待手机上线）'), findsOneWidget);
        expect(find.text('失败：收件人不在手机的“最近来信号码”里'), findsOneWidget);
        await tester.tap(find.widgetWithText(TextButton, '取消'));
        await tester.pumpAndSettle();
        expect(
          rig.server.called('POST', '/api/v1/outbound/t_1/cancel'),
          hasLength(1),
        );
      },
    );
  });

  group('new message', () {
    testWidgets('picks the phone and SIM, sends, and closes', (tester) async {
      final rig = Rig();
      rig.server.routes['POST /api/v1/outbound'] = (_) =>
          (201, taskJson(mode: 'new'));
      await rig.pump(tester);
      await tester.tap(byKey('newMessage'));
      await tester.pumpAndSettle();
      await tester.tap(byKey('newSim'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('SIM2 · 中国联通').last);
      await tester.pumpAndSettle();
      await tester.enterText(byKey('newTo'), '139 0000 0000');
      await tester.enterText(byKey('newBody'), '你好');
      await tester.pump();
      await tester.tap(byKey('newSend'));
      await tester.pumpAndSettle();
      expect(rig.server.called('POST', '/api/v1/outbound').single.body, {
        'deviceId': 'd1',
        'simSlot': 2,
        'to': '139 0000 0000',
        'body': '你好',
      });
      expect(
        byKey('newTo'),
        findsNothing,
        reason: 'the dialog closes once the task is accepted',
      );
    });

    testWidgets('a phone that only allows replies blocks a new message', (
      tester,
    ) async {
      final rig = Rig(
        phone: {'effectivePolicy': 'reply', 'sendPolicy': 'reply'},
      );
      await rig.pump(tester);
      await tester.tap(byKey('newMessage'));
      await tester.pumpAndSettle();
      await tester.enterText(byKey('newTo'), '13900000000');
      await tester.enterText(byKey('newBody'), 'hi');
      await tester.pump();
      expect(find.textContaining('下发策略不允许新发'), findsOneWidget);
      expect(tester.widget<FilledButton>(byKey('newSend')).onPressed, isNull);
    });

    testWidgets('a client without the send permission is told so', (
      tester,
    ) async {
      final rig = Rig(scopes: ['read', 'reply']);
      await rig.pump(tester);
      await tester.tap(byKey('newMessage'));
      await tester.pumpAndSettle();
      expect(find.textContaining('没有“新发”权限'), findsOneWidget);
    });
  });

  group('settings', () {
    Future<void> openSettings(WidgetTester tester) async {
      await tester.tap(byKey('openSettings'));
      await tester.pumpAndSettle();
    }

    testWidgets(
      'shows the connection, and the connection test answers in words',
      (tester) async {
        final rig = Rig();
        await rig.pump(tester);
        await openSettings(tester);
        expect(find.textContaining('权限：查看、回复、新发'), findsOneWidget);
        expect(find.textContaining('长期有效'), findsOneWidget);
        await tester.tap(byKey('testConnection'));
        await tester.pumpAndSettle();
        expect(find.textContaining('连接正常'), findsOneWidget);
      },
    );

    testWidgets(
      'changing the address verifies it first and a wrong one is refused',
      (tester) async {
        final rig = Rig();
        await rig.pump(tester);
        await openSettings(tester);
        rig.server.routes['GET /api/v1/me'] = (_) => (502, '');
        await tester.enterText(
          byKey('settingsUrl'),
          'https://typo.example.com',
        );
        await tester.pump();
        await tester.tap(byKey('saveUrl'));
        await tester.pumpAndSettle();
        expect(find.textContaining('暂时不可用'), findsOneWidget);
        expect(rig.store.value.serverUrl, 'https://sms.example.com');
      },
    );

    testWidgets(
      'platform features appear only where the platform offers them',
      (tester) async {
        final rig = Rig();
        await rig.pump(tester);
        await openSettings(tester);
        expect(find.text('后台运行'), findsNothing);
        expect(byKey('launchAtLogin'), findsNothing);
        expect(byKey('batteryRequest'), findsNothing);
      },
    );

    testWidgets('Android can opt into foreground notifications', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      try {
        final rig = Rig();
        await rig.pump(tester);
        await openSettings(tester);
        await tester.ensureVisible(byKey('foregroundNotifySwitch'));
        expect(
          tester.widget<SwitchListTile>(byKey('foregroundNotifySwitch')).value,
          isFalse,
        );
        await tester.tap(byKey('foregroundNotifySwitch'));
        await tester.pumpAndSettle();
        expect(rig.store.value.foregroundNotifications, isTrue);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets('start with Windows is a switch that writes through the hook', (
      tester,
    ) async {
      final launch = FakeLaunch();
      final rig = Rig(hooks: PlatformHooks(launchAtLogin: launch));
      await rig.pump(tester);
      await openSettings(tester);
      await tester.ensureVisible(byKey('launchAtLogin'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<SwitchListTile>(byKey('launchAtLogin')).value,
        isFalse,
      );
      await tester.tap(byKey('launchAtLogin'));
      await tester.pumpAndSettle();
      expect(launch.enabled, isTrue);
      expect(
        tester.widget<SwitchListTile>(byKey('launchAtLogin')).value,
        isTrue,
      );
    });

    testWidgets(
      'the battery exemption is requested from a button and then shown as done',
      (tester) async {
        final battery = FakeBattery();
        final rig = Rig(hooks: PlatformHooks(battery: battery));
        await rig.pump(tester);
        await openSettings(tester);
        await tester.ensureVisible(byKey('batteryRequest'));
        await tester.pumpAndSettle();
        await tester.tap(byKey('batteryRequest'));
        await tester.pumpAndSettle();
        expect(battery.requested, 1);
        expect(byKey('batteryOk'), findsOneWidget);
      },
    );

    testWidgets('quick replies are editable and used by the reply box', (
      tester,
    ) async {
      final rig = Rig();
      await rig.pump(tester);
      await openSettings(tester);
      await tester.enterText(byKey('quickField'), '好的，收到');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(rig.store.value.quickReplies, ['好的', '收到']);
    });

    testWidgets(
      'signing out asks first, then returns to the connect form and keeps the address',
      (tester) async {
        final rig = Rig();
        await rig.pump(tester);
        await openSettings(tester);
        await tester.dragUntilVisible(
          byKey('signOut'),
          find.byType(ListView),
          const Offset(0, -400),
        );
        await tester.pumpAndSettle();
        await tester.tap(byKey('signOut'));
        await tester.pumpAndSettle();
        expect(find.text('断开连接？'), findsOneWidget);
        await tester.tap(byKey('confirmSignOut'));
        await tester.pumpAndSettle();
        expect(find.text('连接到服务器'), findsOneWidget);
        expect(await rig.tokens.read(), isNull);
        expect(
          tester.widget<TextField>(byKey('serverUrl')).controller!.text,
          'https://sms.example.com',
        );
      },
    );
  });
}
