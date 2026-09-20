/// The state of a connected client: who we are, the conversations, the phones, the live stream, and everything the user
/// can do (read, reply, send). UI-agnostic apart from [ChangeNotifier]; the screens only watch and call it.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../api/api_client.dart';
import '../api/event_stream.dart';
import '../api/models.dart';
import '../api/protocol.dart';
import '../api/server_url.dart';
import '../pairing/connect_request.dart';
import '../pairing/token_store.dart';
import 'settings_store.dart';

enum AppPhase {
  /// Reading the stored settings and checking the token.
  starting,

  /// No usable connection: show the connect screen.
  needsConnect,

  /// Connected (or connected before and currently offline: the token is kept).
  ready,
}

/// How the live channel is doing, for the small indicator in the header.
enum LinkState { connecting, live, offline, noReadPermission }

typedef ApiFactory = ApiClient Function(String baseUrl, String? token);

class AppController extends ChangeNotifier {
  AppController({
    required this.tokens,
    required this.settingsStore,
    required this.appVersion,
    required this.platform,
    this.apiFactory,
    this.defaultDeviceName = '客户端',
    this.onIncoming,
    this.pause,
    this.streamEnabled = true,
  });

  final TokenStore tokens;
  final SettingsStore settingsStore;
  final String appVersion;

  /// `android` / `windows`, sent when pairing (docs/协议.md §3).
  final String platform;
  final ApiFactory? apiFactory;
  final String defaultDeviceName;

  /// Called for every message the server says to alert about (docs/协议.md §5.1 `notify`), after the lists are updated.
  final void Function(Message message)? onIncoming;

  /// Overridable backoff wait so tests do not sleep.
  final Future<void> Function(Duration)? pause;

  /// Whether to open the live event stream (widget tests turn it off: it keeps a timer alive).
  final bool streamEnabled;

  AppPhase phase = AppPhase.starting;
  ClientSettings settings = const ClientSettings();
  Me? me;
  LinkState link = LinkState.connecting;

  /// Last problem worth showing above the lists (connection trouble, permission). Cleared when it resolves.
  String? banner;

  List<Conversation> conversations = const [];
  int unread = 0;
  List<Phone> phones = const [];

  Conversation? selected;
  List<Message> thread = const [];
  List<OutboundTask> tasks = const [];

  Scopes get scopes => Scopes({for (final s in settings.scopes) ?Scope.tryParse(s)});

  /// The latest presence event per phone. Events are the freshest truth while the stream is live, so a list that was
  /// fetched while an event arrived must not overwrite it with an older answer.
  final _presence = <String, DeviceEvent>{};

  ApiClient? _api;
  EventStreamRunner? _stream;
  bool _disposed = false;
  bool _refreshing = false, _refreshAgain = false;

  ApiClient _newApi(String baseUrl, String? token) => (apiFactory ?? (u, t) => ApiClient(baseUrl: u, token: t))(baseUrl, token);

  // --- start / connect / sign out ----------------------------------------------------------------------------

  /// Reads the stored settings and, if there is a token, checks it and goes live.
  Future<void> start() async {
    settings = await settingsStore.load();
    final token = await tokens.read();
    final url = settings.serverUrl;
    if (token == null || url == null) {
      _setPhase(AppPhase.needsConnect);
      return;
    }
    _api = _newApi(url, token);
    // Show the app right away with what we know; the check below only corrects it. A phone that is offline at launch
    // must still open, because the token is kept through any connectivity problem.
    _setPhase(AppPhase.ready);
    await _enter();
  }

  /// Pairs with a code, or logs in with the account, and stores the long-lived token. Returns the text to show, or
  /// null on success.
  Future<String?> connect(ConnectRequest request) async {
    final client = _newApi(request.serverUrl, null);
    try {
      final result = request.mode == ConnectMode.pairingCode
          ? await client.claim(code: request.pairingCode!, name: request.deviceName, platform: platform, appVersion: appVersion)
          : await client.loginDevice(
              password: request.password!, name: request.deviceName, platform: platform, appVersion: appVersion, totp: request.totp);
      if (result.token.isEmpty) return '服务器返回的内容无法识别，请检查地址';
      await tokens.write(result.token);
      settings = settings.copyWith(serverUrl: request.serverUrl, deviceName: request.deviceName, deviceId: result.deviceId, scopes: result.scopes);
      await settingsStore.save(settings);
      _api = _newApi(request.serverUrl, result.token);
      banner = null;
      _setPhase(AppPhase.ready);
      await _enter();
      return null;
    } on ApiException catch (e) {
      return e.text;
    } finally {
      client.close();
    }
  }

  /// Signs out: forgets the token and the device identity, keeps the address and name so connecting again is quick.
  Future<void> signOut() async {
    await _stopLive();
    await tokens.clear();
    settings = settings.copyWith(clearIdentity: true);
    await settingsStore.save(settings);
    _api?.close();
    _api = null;
    me = null;
    conversations = const [];
    phones = const [];
    selected = null;
    thread = const [];
    tasks = const [];
    unread = 0;
    banner = null;
    _setPhase(AppPhase.needsConnect);
  }

  /// A token the server rejected: back to the connect screen. Settings stay, only the token goes (docs/协议.md §2.2).
  Future<void> _tokenDied() async {
    await signOut();
    banner = '登录已失效（令牌被吊销或已过期），请重新连接。';
    notifyListeners();
  }

  Future<void> _enter() async {
    final api = _api;
    if (api == null) return;
    try {
      final who = await api.me();
      me = who;
      settings = settings.copyWith(deviceId: who.deviceId, scopes: {for (final s in ['read', 'reply', 'send']) if (_has(who.scopes, s)) s});
      await settingsStore.save(settings);
      banner = null;
    } on ApiException catch (e) {
      if (e.isTokenDead) return _tokenDied();
      // Anything else (offline, proxy hiccup, wrong address): keep the token and the app open, retry through the stream.
      banner = e.text;
    }
    notifyListeners();
    if (scopes.canRead) {
      await refreshAll();
      _startStream();
    } else {
      link = LinkState.noReadPermission;
      banner = '这个客户端没有“查看”权限，无法显示短信。可以在 Web 的设备页调整。';
      notifyListeners();
    }
  }

  bool _has(Scopes s, String name) => switch (name) {
        'read' => s.canRead,
        'reply' => s.canReply,
        _ => s.canSend,
      };

  void _startStream() {
    final api = _api;
    if (api == null || !streamEnabled) return;
    _stream?.stop();
    _stream = EventStreamRunner(
      client: api,
      onEvent: _onEvent,
      // A fresh connection is not replayed: fetch what happened before it existed.
      onConnected: () => unawaited(refreshAll()),
      onStatus: _onStreamStatus,
      pause: pause,
    );
    unawaited(_stream!.run());
  }

  Future<void> _stopLive() async {
    _stream?.stop();
    _stream = null;
  }

  void _onStreamStatus(StreamStatus s) {
    switch (s) {
      case StreamStatus.live:
        link = LinkState.live;
        if (banner != null && banner!.startsWith('无法')) banner = null;
      case StreamStatus.connecting:
        link = LinkState.connecting;
      case StreamStatus.waiting:
        link = LinkState.offline;
        _presence.clear(); // without the stream nobody tells us about changes: trust the next fetch again
      case StreamStatus.forbidden:
        link = LinkState.noReadPermission;
        banner = '这个客户端没有“查看”权限，无法显示短信。可以在 Web 的设备页调整。';
      case StreamStatus.tokenDead:
        unawaited(_tokenDied());
        return;
      case StreamStatus.idle:
        break;
    }
    if (!_disposed) notifyListeners();
  }

  // --- reading -------------------------------------------------------------------------------------------------

  /// Refetches everything shown on screen. Concurrent calls collapse into one follow-up run.
  Future<void> refreshAll() async {
    if (_refreshing) {
      _refreshAgain = true;
      return;
    }
    _refreshing = true;
    try {
      do {
        _refreshAgain = false;
        await _refreshOnce();
      } while (_refreshAgain && !_disposed);
    } finally {
      _refreshing = false;
    }
  }

  Future<void> _refreshOnce() async {
    final api = _api;
    if (api == null) return;
    try {
      final list = await api.conversations();
      conversations = list.items;
      unread = list.unread;
      if (scopes.canRead) phones = _withPresence(await api.phones());
      final open = selected;
      if (open != null) {
        final still = conversations.where((c) => c.key == open.key);
        selected = still.isEmpty ? open : still.first;
        await _loadThread();
      }
      if (banner != null && link == LinkState.live) banner = null;
    } on ApiException catch (e) {
      if (e.isTokenDead) {
        await _tokenDied();
        return;
      }
      if (e.code == ErrorCodes.scopeDenied) {
        link = LinkState.noReadPermission;
        banner = '这个客户端没有“查看”权限，无法显示短信。可以在 Web 的设备页调整。';
      } else {
        banner = e.text;
      }
    }
    if (!_disposed) notifyListeners();
  }

  Future<void> _loadThread() async {
    final api = _api, open = selected;
    if (api == null || open == null) return;
    thread = await api.thread(open.deviceId, open.peerKey);
    tasks = scopes.canRead ? await api.outbound(deviceId: open.deviceId, peer: open.peerKey, limit: 3) : const [];
    if (thread.any((m) => m.isUnread)) {
      await api.markThreadRead(open.deviceId, open.peer);
      thread = [for (final m in thread) m.isUnread ? m.copyWith(readAt: DateTime.now().millisecondsSinceEpoch) : m];
      final list = await api.conversations();
      conversations = list.items;
      unread = list.unread;
    }
  }

  Future<void> openConversation(Conversation? c) async {
    selected = c;
    thread = const [];
    tasks = const [];
    notifyListeners();
    if (c == null) return;
    try {
      await _loadThread();
    } on ApiException catch (e) {
      banner = e.text;
    }
    if (!_disposed) notifyListeners();
  }

  void _onEvent(ServerEvent e) {
    switch (e) {
      case MessageEvent(:final message, :final notify):
        // The simple, correct thing: the server owns unread counts and ordering, so refetch instead of patching.
        // Alert first: the notification must not wait for two round trips.
        if (notify) onIncoming?.call(message);
        unawaited(refreshAll());
      case ReadEvent() || DeletedEvent() || ResyncEvent() || OutboundEvent():
        unawaited(refreshAll());
      case DeviceEvent():
        _presence[e.deviceId] = e;
        phones = _withPresence(phones);
        notifyListeners();
      case UnknownEvent():
        break;
    }
  }

  List<Phone> _withPresence(List<Phone> list) => [
        for (final p in list)
          if (_presence[p.id] case final DeviceEvent ev?)
            Phone(
              id: p.id,
              name: p.name,
              sims: p.sims,
              online: ev.online,
              revoked: p.revoked,
              sendPolicy: p.sendPolicy,
              phoneSendPolicy: p.phoneSendPolicy,
              effectivePolicy: p.effectivePolicy,
              battery: ev.battery ?? p.battery,
            )
          else
            p,
      ];

  // --- sending -------------------------------------------------------------------------------------------------

  Phone? phoneFor(String deviceId) {
    for (final p in phones) {
      if (p.id == deviceId) return p;
    }
    return null;
  }

  /// The message a reply answers: the latest received one of the open conversation.
  Message? get replyTarget {
    for (final m in thread.reversed) {
      if (m.isIncoming) return m;
    }
    return null;
  }

  /// Why the open conversation cannot be replied to, or null.
  String? get replyBlockedReason {
    final c = selected;
    if (c == null) return '先选择一个会话';
    if (!scopes.canReply) return '这个客户端没有“回复”权限，可以在 Web 的设备页调整';
    if (!c.replyable) return '字母 / 名称发件人无法回复';
    if (replyTarget == null) return '这个会话里没有收到过短信，无法回复（可以用「新短信」）';
    final phone = phoneFor(c.deviceId);
    if (phone == null) return '找不到这台手机';
    return phone.blockedReason(reply: true);
  }

  /// Sends [text] as a reply. Returns an error text, or null when the task was accepted.
  Future<String?> sendReply(String text) async {
    final target = replyTarget, api = _api;
    if (target == null || api == null) return '无法回复';
    try {
      await api.reply(target.id, text);
      await _refreshTasks();
      return null;
    } on ApiException catch (e) {
      if (e.isTokenDead) {
        unawaited(_tokenDied());
      }
      return e.text;
    }
  }

  Future<String?> sendNew({required String deviceId, int? simSlot, required String to, required String body}) async {
    final api = _api;
    if (api == null) return '还没有连接';
    try {
      await api.sendNew(deviceId: deviceId, simSlot: simSlot, to: to, body: body);
      await _refreshTasks();
      return null;
    } on ApiException catch (e) {
      if (e.isTokenDead) unawaited(_tokenDied());
      return e.text;
    }
  }

  Future<String?> cancelTask(String taskId) async {
    try {
      await _api?.cancelOutbound(taskId);
      await _refreshTasks();
      return null;
    } on ApiException catch (e) {
      return e.text;
    }
  }

  Future<void> _refreshTasks() async {
    final api = _api, open = selected;
    if (api == null || open == null) return;
    try {
      tasks = await api.outbound(deviceId: open.deviceId, peer: open.peerKey, limit: 3);
    } on ApiException {
      // The list is only a convenience; the send itself already succeeded.
    }
    if (!_disposed) notifyListeners();
  }

  Future<void> markAllRead() async {
    final api = _api;
    if (api == null) return;
    for (final c in conversations.where((c) => c.unread > 0)) {
      try {
        await api.markThreadRead(c.deviceId, c.peer);
      } on ApiException {
        break;
      }
    }
    await refreshAll();
  }

  // --- settings ------------------------------------------------------------------------------------------------

  Future<void> updateSettings(ClientSettings next) async {
    settings = next;
    await settingsStore.save(next);
    notifyListeners();
  }

  /// "Test connection": asks the server who we are. Also notices a revoked token.
  Future<String> testConnection() async {
    final api = _api;
    if (api == null) return '还没有连接';
    try {
      final who = await api.me();
      me = who;
      notifyListeners();
      return '连接正常 · 服务器 ${who.serverVersion ?? '?'} · 令牌有效';
    } on ApiException catch (e) {
      if (e.isTokenDead) unawaited(_tokenDied());
      return e.text;
    }
  }

  /// Points the client at another address (new domain, new port). No new login: the token does not depend on the
  /// address. It is only saved when the server there recognises this very device, so a typo cannot lock the client out.
  Future<String?> changeServerUrl(String raw) async {
    final checked = ServerUrl.validate(raw);
    if (checked is ServerUrlInvalid) return serverUrlProblemText(checked.problem);
    final url = (checked as ServerUrlOk).url;
    final token = await tokens.read();
    if (token == null) return '还没有连接';
    final probe = _newApi(url, token);
    try {
      final who = await probe.me();
      if (who.deviceId != settings.deviceId) return '那个地址上的服务器不认识这个客户端（设备不一致），没有保存。换服务器请重新连接';
      settings = settings.copyWith(serverUrl: url);
      await settingsStore.save(settings);
      await _stopLive();
      _api?.close();
      _api = _newApi(url, token);
      await _enter();
      return null;
    } on ApiException catch (e) {
      return e.isTokenDead ? '那个地址上的服务器不认识这个客户端的令牌，没有保存。换服务器请重新连接' : e.text;
    } finally {
      probe.close();
    }
  }

  /// The network came back or the app returned to the foreground: reconnect the stream now.
  void nudge() => _stream?.nudge();

  void _setPhase(AppPhase p) {
    phase = p;
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _stream?.stop();
    _api?.close();
    super.dispose();
  }
}

