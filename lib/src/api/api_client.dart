/// The REST side of the server API that this client uses (docs/协议.md §3, §4). No Flutter imports: the same code runs in
/// the UI and in the Android background service.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'connection.dart';
import 'models.dart';

/// Why a request failed, for choosing the words shown to the user.
enum FailureKind { http, network, timeout, tls, notOurServer }

/// A failed request, carrying what it means for the stored token ([verdict], docs/协议.md §2.2).
class ApiException implements Exception {
  ApiException({required this.kind, this.status, this.code, this.message});

  final FailureKind kind;
  final int? status;

  /// The server's own `error` code, when the body was its JSON.
  final String? code;
  final String? message;

  ConnectionVerdict get verdict {
    if (kind == FailureKind.notOurServer)
      return ConnectionVerdict.addressSuspect;
    return Connection.classify(httpStatus: status, errorCode: code);
  }

  bool get isTokenDead => verdict == ConnectionVerdict.needsPairing;

  /// A refusal the server made on purpose ("you may not do that"), as opposed to a connection problem.
  bool get isDenied =>
      status != null &&
      code != null &&
      (status == 403 ||
          status == 409 ||
          status == 422 ||
          status == 429 ||
          status == 400);

  @override
  String toString() => 'ApiException($kind, status: $status, code: $code)';

  /// Words for the user. Server refusals get specific text; connection problems follow docs/协议.md §2.2.
  String get text {
    switch (code) {
      case 'invalid_credentials':
        return '密码不正确';
      case 'totp_required':
        return '服务器已开启二次验证，请填写动态验证码';
      case 'invalid_totp':
        return '动态验证码不正确，请核对手机时间后重试';
      case 'totp_unavailable':
        return '服务器无法读取二次验证密钥，请检查服务端配置';
      case 'too_many_attempts':
        return '尝试次数太多，请稍后再试';
      case 'setup_required':
        return '服务器还没有完成初始设置，请先在网页里创建管理员';
      case 'invalid_pair_code':
        return '配对码错误、已过期或已被使用';
      case 'pair_kind_mismatch':
        return '这是接收端的配对码。客户端需要在 Web「设备与客户端」里选择“客户端”来生成配对码';
      case 'scope_denied':
        return '这个客户端没有该操作的权限，可以在 Web 的设备页调整';
      case 'policy_denied':
        return '这台手机的下发策略不允许（先在 Web 里调整平台策略，手机上也要开启）';
      case 'reply_not_supported':
        return '字母 / 名称发件人无法回复';
      case 'rate_limited':
        return '发送太频繁，请稍后再试';
      case 'bad_body':
        return '短信内容不能为空，且不超过 1000 个字';
      case 'bad_recipient':
        return '收件人号码格式不对';
      case 'bad_sim_slot':
        return '这台手机没有这个 SIM 卡槽';
      case 'device_revoked':
        return '这台手机的令牌已被吊销，需要先重新配对';
      case 'not_cancellable':
        return '任务已经交给手机，无法取消';
      case 'message_not_found':
        return '原短信已不存在';
    }
    return switch (kind) {
      _ when verdict == ConnectionVerdict.needsPairing => '令牌已失效，需要重新连接',
      FailureKind.network => '无法连接到服务器，请检查地址和网络',
      FailureKind.timeout => '连接服务器超时',
      FailureKind.tls => '服务器证书无效或不受信任（域名不匹配、证书过期，或使用了自签名证书）',
      FailureKind.notOurServer =>
        '这个地址不像 NyaSmsForward 服务器，请检查地址（是否需要 https://，或被反向代理拦截）',
      FailureKind.http when status == 429 => '请求太频繁，请稍后再试',
      FailureKind.http when status != null && status! >= 500 =>
        '服务器暂时不可用（HTTP $status），请稍后再试',
      FailureKind.http when verdict == ConnectionVerdict.addressSuspect =>
        '这个地址不像 NyaSmsForward 服务器，请检查地址（HTTP $status）',
      _ =>
        '服务器拒绝了请求${code != null
            ? '（$code）'
            : status != null
            ? '（HTTP $status）'
            : ''}',
    };
  }
}

class ClaimResult {
  const ClaimResult({
    required this.deviceId,
    required this.token,
    required this.scopes,
  });
  final String deviceId;
  final String token;
  final Set<String> scopes;
}

class ApiClient {
  ApiClient({
    required String baseUrl,
    this.token,
    http.Client? httpClient,
    this.timeout = const Duration(seconds: 15),
  }) : baseUrl = baseUrl.replaceFirst(RegExp(r'/+$'), ''),
       _http = httpClient ?? http.Client();

  final String baseUrl;
  final String? token;
  final Duration timeout;
  final http.Client _http;

  void close() => _http.close();

  Map<String, String> get _headers => {
    'Accept': 'application/json',
    if (token != null)
      'Authorization':
          'Bearer $token', // only ever in this header, never in the URL
  };

  // --- pairing -----------------------------------------------------------------------------------------------

  Future<ClaimResult> claim({
    required String code,
    required String name,
    required String platform,
    required String appVersion,
  }) async {
    final j = await _send(
      'POST',
      '/api/v1/pair/claim',
      body: {
        'code': code,
        'name': name,
        'kind': 'client',
        'platform': platform,
        'appVersion': appVersion,
      },
    );
    return _claimResult(j);
  }

  /// Exchanges the admin password for a device token (docs/协议.md §3.1). The password is not kept anywhere.
  Future<ClaimResult> loginDevice({
    required String password,
    required String name,
    required String platform,
    required String appVersion,
    String? totp,
  }) async {
    final j = await _send(
      'POST',
      '/api/v1/auth/login-device',
      body: {
        'password': password,
        'name': name,
        'kind': 'client',
        'platform': platform,
        'appVersion': appVersion,
        'totp': ?totp,
      },
    );
    return _claimResult(j);
  }

  ClaimResult _claimResult(Map<String, Object?> j) => ClaimResult(
    deviceId: j['deviceId'] as String? ?? '',
    token: j['token'] as String? ?? '',
    scopes: {
      for (final s in (j['scopes'] as List?) ?? const [])
        if (s is String) s,
    },
  );

  Future<Me> me() async => Me.fromJson(await _send('GET', '/api/v1/me'));

  // --- reading -----------------------------------------------------------------------------------------------

  Future<({List<Conversation> items, int unread})> conversations({
    String? query,
    String? deviceId,
    bool unreadOnly = false,
  }) async {
    final j = await _send(
      'GET',
      '/api/v1/conversations',
      query: {
        'q': query,
        'device': deviceId,
        'unread': unreadOnly ? '1' : null,
        'limit': '200',
      },
    );
    return (
      items: [
        for (final c in (j['items'] as List?) ?? const [])
          Conversation.fromJson((c as Map).cast<String, Object?>()),
      ],
      unread: (j['unread'] as num?)?.toInt() ?? 0,
    );
  }

  Future<List<Message>> thread(
    String deviceId,
    String peerKey, {
    String? cardNumber,
  }) async {
    final j = await _send(
      'GET',
      '/api/v1/messages',
      query: {
        'device': cardNumber == null || cardNumber.isEmpty ? deviceId : null,
        'card': cardNumber,
        'peer': peerKey,
        'limit': '200',
      },
    );
    final items = [
      for (final m in (j['items'] as List?) ?? const [])
        Message.fromJson((m as Map).cast<String, Object?>()),
    ];
    items.sort(
      (a, b) => a.deviceTime != b.deviceTime
          ? a.deviceTime.compareTo(b.deviceTime)
          : a.id.compareTo(b.id),
    );
    return items;
  }

  /// Newest unread incoming messages, used when a background service starts
  /// without a previous SSE Last-Event-ID to replay.
  Future<List<Message>> unreadMessages({int limit = 50}) async {
    final j = await _send(
      'GET',
      '/api/v1/messages',
      query: {'unread': '1', 'limit': '$limit'},
    );
    final items = [
      for (final m in (j['items'] as List?) ?? const [])
        Message.fromJson((m as Map).cast<String, Object?>()),
    ];
    items.sort((a, b) => a.id.compareTo(b.id));
    return items;
  }

  Future<List<Phone>> phones() async {
    final j = await _send('GET', '/api/v1/phones');
    return [
      for (final p in (j['items'] as List?) ?? const [])
        Phone.fromJson((p as Map).cast<String, Object?>()),
    ];
  }

  Future<List<int>> markThreadRead(
    String deviceId,
    String peer, {
    String? cardNumber,
  }) async {
    final j = await _send(
      'POST',
      '/api/v1/messages/read',
      body: cardNumber == null || cardNumber.isEmpty
          ? {'deviceId': deviceId, 'peer': peer}
          : {'cardNumber': cardNumber, 'peer': peer},
    );
    return [
      for (final i in (j['changed'] as List?) ?? const []) (i as num).toInt(),
    ];
  }

  Future<void> markRead(List<int> ids) async =>
      _send('POST', '/api/v1/messages/read', body: {'ids': ids});

  Future<List<int>> deleteMessages(List<int> ids) async {
    final j = await _send(
      'POST',
      '/api/v1/messages/delete',
      body: {'ids': ids},
    );
    return [
      for (final i in (j['deleted'] as List?) ?? const []) (i as num).toInt(),
    ];
  }

  /// Moves all messages in each selected number thread to the recycle bin, without a page-size limit.
  Future<int> deleteConversations(List<Conversation> conversations) async {
    final j = await _send(
      'POST',
      '/api/v1/messages/delete-conversations',
      body: {
        'conversations': [
          for (final c in conversations)
            {
              'peerKey': c.peerKey,
              if (c.cardNumber == null || c.cardNumber!.isEmpty)
                'deviceId': c.deviceId
              else
                'cardNumber': c.cardNumber,
            },
        ],
      },
    );
    return (j['deleted'] as num?)?.toInt() ?? 0;
  }

  Future<List<Message>> deletedMessages() async {
    final j = await _send('GET', '/api/v1/messages/deleted');
    return [
      for (final m in (j['items'] as List?) ?? const [])
        Message.fromJson((m as Map).cast<String, Object?>()),
    ];
  }

  Future<void> restoreMessage(int id) async =>
      _send('POST', '/api/v1/messages/$id/restore');

  // --- sending -----------------------------------------------------------------------------------------------

  /// Reply to a received message: recipient, phone and SIM come from that message.
  Future<OutboundTask> reply(int messageId, String body) async =>
      OutboundTask.fromJson(
        await _send(
          'POST',
          '/api/v1/outbound',
          body: {'replyToMessageId': messageId, 'body': body},
        ),
      );

  Future<OutboundTask> sendNew({
    required String deviceId,
    int? simSlot,
    required String to,
    required String body,
  }) async => OutboundTask.fromJson(
    await _send(
      'POST',
      '/api/v1/outbound',
      body: {'deviceId': deviceId, 'simSlot': ?simSlot, 'to': to, 'body': body},
    ),
  );

  Future<List<OutboundTask>> outbound({
    String? deviceId,
    String? peer,
    int limit = 5,
  }) async {
    final j = await _send(
      'GET',
      '/api/v1/outbound',
      query: {'device': deviceId, 'peer': peer, 'limit': '$limit'},
    );
    return [
      for (final t in (j['items'] as List?) ?? const [])
        OutboundTask.fromJson((t as Map).cast<String, Object?>()),
    ];
  }

  Future<OutboundTask> cancelOutbound(String taskId) async =>
      OutboundTask.fromJson(
        await _send('POST', '/api/v1/outbound/$taskId/cancel'),
      );

  // --- streaming ---------------------------------------------------------------------------------------------

  /// Opens the event stream (docs/协议.md §6.1). The caller reads the body and closes it by cancelling the subscription.
  Future<http.StreamedResponse> openEvents({String? lastEventId}) async {
    final request = http.Request('GET', Uri.parse('$baseUrl/api/v1/events'))
      ..headers.addAll({
        ..._headers,
        'Accept': 'text/event-stream',
        'Cache-Control': 'no-cache',
        'Last-Event-ID': ?lastEventId,
      });
    try {
      final response = await _http.send(request).timeout(timeout);
      if (response.statusCode != 200) {
        final body = await response.stream.bytesToString();
        throw _httpFailure(response.statusCode, body);
      }
      return response;
    } on ApiException {
      rethrow;
    } on Object catch (e) {
      throw _transportFailure(e);
    }
  }

  // --- plumbing ----------------------------------------------------------------------------------------------

  Future<Map<String, Object?>> _send(
    String method,
    String path, {
    Map<String, Object?>? body,
    Map<String, String?>? query,
  }) async {
    final params = {
      for (final e in (query ?? const <String, String?>{}).entries)
        if (e.value != null && e.value!.isNotEmpty) e.key: e.value!,
    };
    final uri = Uri.parse('$baseUrl$path')
        .replace(queryParameters: params.isEmpty ? null : params);
    final request = http.Request(method, uri)..headers.addAll(_headers);
    if (method != 'GET') {
      request.headers['Content-Type'] = 'application/json; charset=utf-8';
      request.bodyBytes = utf8.encode(jsonEncode(body ?? const {}));
    }
    try {
      final response = await _http.send(request).timeout(timeout);
      final text = await response.stream.bytesToString().timeout(timeout);
      if (response.statusCode >= 300 && response.statusCode < 400) {
        // A redirect almost always means "you typed http:// but the server wants https://".
        throw ApiException(
          kind: FailureKind.notOurServer,
          status: response.statusCode,
          message: 'redirect',
        );
      }
      if (response.statusCode >= 400)
        throw _httpFailure(response.statusCode, text);
      if (response.statusCode == 204 || text.isEmpty) return const {};
      final decoded = jsonDecode(text);
      // A 2xx that is not our JSON: a captive portal, a proxy's landing page, the wrong service on that port.
      if (decoded is! Map)
        throw ApiException(
          kind: FailureKind.notOurServer,
          status: response.statusCode,
          message: 'unexpected body',
        );
      return decoded.cast<String, Object?>();
    } on ApiException {
      rethrow;
    } on FormatException {
      throw ApiException(
        kind: FailureKind.notOurServer,
        status: 200,
        message: 'unexpected body',
      );
    } on Object catch (e) {
      throw _transportFailure(e);
    }
  }

  ApiException _httpFailure(int status, String text) {
    String? code, message;
    try {
      final j = jsonDecode(text);
      if (j is Map) {
        code = j['error'] is String ? j['error'] as String : null;
        message = j['message'] is String ? j['message'] as String : null;
      }
    } on FormatException {
      // not JSON (e.g. a proxy error page): keep the generic failure
    }
    return ApiException(
      kind: FailureKind.http,
      status: status,
      code: code,
      message: message,
    );
  }

  ApiException _transportFailure(Object e) => switch (e) {
    TimeoutException() => ApiException(
      kind: FailureKind.timeout,
      message: '$e',
    ),
    HandshakeException() ||
    TlsException() => ApiException(kind: FailureKind.tls, message: '$e'),
    _ => ApiException(kind: FailureKind.network, message: '$e'),
  };
}
