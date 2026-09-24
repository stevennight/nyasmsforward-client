// Renders the main screens to PNG files with real fonts, so the look can be reviewed without a device:
//
//   NYASMS_SHOTS=1 flutter test test/visual --update-goldens
//
// The images land in test/visual/shots/ (git-ignored). Skipped in normal test runs: the fonts come from the local
// Flutter SDK and Windows, which CI does not have.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_server.dart';
import '../ui/screens_test.dart' show Rig;

final bool _enabled = Platform.environment['NYASMS_SHOTS'] == '1';

Future<void> _loadFont(String family, List<String> paths) async {
  final loader = FontLoader(family);
  for (final p in paths) {
    final f = File(p);
    if (f.existsSync()) loader.addFont(Future.value(ByteData.sublistView(f.readAsBytesSync())));
  }
  await loader.load();
}

Future<void> _loadFonts() async {
  final sdk = Platform.environment['FLUTTER_ROOT'] ?? 'C:/src/flutter';
  final icons = '$sdk/bin/cache/artifacts/material_fonts/materialicons-regular.otf';
  const cjk = ['C:/Windows/Fonts/Deng.ttf', 'C:/Windows/Fonts/Dengb.ttf'];
  for (final family in ['FlutterTest', 'Roboto', 'Segoe UI', 'Microsoft YaHei', 'monospace', '.SF UI Text']) {
    await _loadFont(family, cjk);
  }
  await _loadFont('MaterialIcons', [icons]);
}

List<Map<String, Object?>> _conversations() => [
      convJson(msgJson(12, peer: '10086', body: '【中国移动】您本月话费账单：套餐费 58.00 元，已从账户扣除。'), unread: 2),
      convJson(msgJson(11, peer: '13800000000', body: '晚上一起吃饭吗？我七点到。', direction: 'out'), unread: 0),
      convJson(msgJson(10, peer: '95588', body: '【工商银行】您尾号 1234 卡 09:12 支出 58.00 元，余额 2,310.45 元。', readAt: 1), unread: 0),
      convJson(msgJson(9, peer: '106905551234', body: '【示例快递】您的包裹已放入 3 号柜，取件码 4-7-2011。', readAt: 1), unread: 0),
    ];

Future<void> _shoot(WidgetTester tester, String name) async {
  await tester.pumpAndSettle();
  await expectLater(find.byType(MaterialApp), matchesGoldenFile('shots/$name.png'));
}

void main() {
  setUpAll(() async {
    if (_enabled) await _loadFonts();
  });

  testWidgets('desktop: inbox with a conversation open', (tester) async {
    final rig = Rig(extraConversations: _conversations());
    await rig.pump(tester, size: const Size(1280, 800));
    await rig.controller.openConversation(rig.controller.conversations.first);
    await _shoot(tester, 'desktop_inbox');
  }, skip: !_enabled);

  testWidgets('phone: conversation list', (tester) async {
    final rig = Rig(extraConversations: _conversations());
    await rig.pump(tester, size: const Size(412, 900));
    await _shoot(tester, 'phone_list');
  }, skip: !_enabled);

  testWidgets('phone: conversation', (tester) async {
    final rig = Rig(extraConversations: _conversations());
    await rig.pump(tester, size: const Size(412, 900));
    await rig.controller.openConversation(rig.controller.conversations.first);
    await _shoot(tester, 'phone_thread');
  }, skip: !_enabled);

  testWidgets('phone: settings', (tester) async {
    final rig = Rig(extraConversations: _conversations());
    await rig.pump(tester, size: const Size(412, 900));
    await tester.tap(find.byKey(const Key('openSettings')));
    await _shoot(tester, 'phone_settings');
  }, skip: !_enabled);

  testWidgets('phone: not connected', (tester) async {
    final rig = Rig(connected: false);
    await rig.pump(tester, size: const Size(412, 900));
    await _shoot(tester, 'phone_connect');
  }, skip: !_enabled);
}
