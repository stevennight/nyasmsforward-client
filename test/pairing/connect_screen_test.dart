import 'package:client/src/app/app.dart';
import 'package:client/src/pairing/connect_screen.dart';
import 'package:client/src/pairing/token_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> pumpScreen(WidgetTester tester, {ConnectHandler? onConnect}) async {
  tester.view.physicalSize = const Size(900, 1400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(NyaApp(home: ConnectScreen(onConnect: onConnect ?? notImplementedYet)));
}

Future<void> tapConnect(WidgetTester tester) async {
  await tester.ensureVisible(find.byKey(const Key('connect')));
  await tester.tap(find.byKey(const Key('connect')));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('shows the pairing form and never offers a way to skip connecting', (tester) async {
    await pumpScreen(tester);
    expect(find.text('连接到服务器'), findsOneWidget);
    expect(find.byKey(const Key('pairingCode')), findsOneWidget);
    expect(find.byKey(const Key('password')), findsNothing);
  });

  testWidgets('a public http address is rejected with an explanation', (tester) async {
    var called = false;
    await pumpScreen(tester, onConnect: (_) async {
      called = true;
      return null;
    });
    await tester.enterText(find.byKey(const Key('serverUrl')), 'http://sms.example.com');
    await tester.enterText(find.byKey(const Key('pairingCode')), '123456');
    await tapConnect(tester);

    expect(find.textContaining('公网地址必须使用 HTTPS'), findsOneWidget);
    expect(called, isFalse, reason: 'invalid input must not reach the pairing handler');
  });

  testWidgets('an empty address and a short pairing code are both reported', (tester) async {
    await pumpScreen(tester);
    await tester.enterText(find.byKey(const Key('pairingCode')), '12');
    await tapConnect(tester);

    expect(find.text('请填写服务器地址'), findsOneWidget);
    expect(find.text('配对码是 6 位数字'), findsOneWidget);
  });

  testWidgets('valid pairing input reaches the handler with a normalized address', (tester) async {
    ConnectRequest? seen;
    await pumpScreen(tester, onConnect: (r) async {
      seen = r;
      return null;
    });
    await tester.enterText(find.byKey(const Key('serverUrl')), ' https://sms.example.com/ ');
    await tester.enterText(find.byKey(const Key('pairingCode')), '483 920');
    await tapConnect(tester);

    expect(seen, isNotNull);
    expect(seen!.serverUrl, 'https://sms.example.com');
    expect(seen!.mode, ConnectMode.pairingCode);
    expect(seen!.pairingCode, '483920');
    expect(seen!.password, isNull);
  });

  testWidgets('account login asks for the admin password and validates the optional TOTP', (tester) async {
    ConnectRequest? seen;
    await pumpScreen(tester, onConnect: (r) async {
      seen = r;
      return null;
    });
    await tester.tap(find.text('账号登录'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('password')), findsOneWidget);
    expect(find.byKey(const Key('pairingCode')), findsNothing);

    await tester.enterText(find.byKey(const Key('serverUrl')), 'https://sms.example.com');
    await tapConnect(tester);
    expect(find.text('请输入管理员密码'), findsOneWidget);

    await tester.enterText(find.byKey(const Key('password')), 'secret');
    await tester.enterText(find.byKey(const Key('totp')), '12');
    await tapConnect(tester);
    expect(find.text('动态验证码是 6 位数字'), findsOneWidget);

    await tester.enterText(find.byKey(const Key('totp')), '123456');
    await tapConnect(tester);
    expect(seen!.mode, ConnectMode.accountLogin);
    expect(seen!.password, 'secret');
    expect(seen!.totp, '123456');
    expect(seen!.pairingCode, isNull);
  });

  testWidgets('a message from the handler is shown to the user', (tester) async {
    await pumpScreen(tester, onConnect: (_) async => '配对码无效或已过期');
    await tester.enterText(find.byKey(const Key('serverUrl')), 'https://sms.example.com');
    await tester.enterText(find.byKey(const Key('pairingCode')), '111111');
    await tapConnect(tester);
    expect(find.byKey(const Key('message')), findsOneWidget);
    expect(find.text('配对码无效或已过期'), findsOneWidget);
  });

  test('the in-memory token store round-trips and clears', () async {
    final store = MemoryTokenStore();
    expect(await store.read(), isNull);
    await store.write('nsf_abc');
    expect(await store.read(), 'nsf_abc');
    await store.clear();
    expect(await store.read(), isNull);
  });
}
