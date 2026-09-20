import 'dart:async';
import 'dart:convert';

import 'package:client/src/api/api_client.dart';
import 'package:client/src/session/app_controller.dart';
import 'package:http/http.dart' as http;

class Req {
  Req(this.method, this.uri, this.headers, this.body);
  final String method;
  final Uri uri;
  final Map<String, String> headers;
  final Object? body;

  String get path => uri.path;
}

/// A scripted server as an `http.Client`: routes are `"METHOD /path"` -> handler returning a body, `(status, body)`, or
/// throwing. `GET /api/v1/events` is a stream the test controls through [openStreams].
class FakeServer extends http.BaseClient {
  FakeServer([Map<String, Object? Function(Req)>? routes]) : routes = routes ?? {};

  final Map<String, Object? Function(Req)> routes;
  final List<Req> calls = [];

  /// One controller per event-stream connection, in order of connection.
  final List<StreamController<List<int>>> openStreams = [];
  final List<Req> streamRequests = [];

  /// Failures for the next stream connections, in order (status and body); once empty, connections succeed.
  final List<({int status, String body})> streamFailures = [];

  set streamFailure(({int status, String body}) f) => streamFailures.add(f);

  Iterable<Req> called(String method, String path) => calls.where((c) => c.method == method && c.path == path);

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final text = (request as http.Request).body;
    Object? body;
    if (text.isNotEmpty) body = jsonDecode(text);
    final req = Req(request.method, request.url, request.headers, body);

    if (req.method == 'GET' && req.path == '/api/v1/events') {
      streamRequests.add(req);
      if (streamFailures.isNotEmpty) {
        final failure = streamFailures.removeAt(0);
        return http.StreamedResponse(Stream.value(utf8.encode(failure.body)), failure.status, headers: {'content-type': 'application/json'});
      }
      final c = StreamController<List<int>>();
      openStreams.add(c);
      return http.StreamedResponse(c.stream, 200, headers: {'content-type': 'text/event-stream'});
    }

    calls.add(req);
    final handler = routes['${req.method} ${req.path}'];
    if (handler == null) return _json(404, {'error': 'not_found'});
    final result = handler(req);
    if (result is (int, Object?)) return _json(result.$1, result.$2);
    return _json(200, result);
  }

  http.StreamedResponse _json(int status, Object? body) {
    final bytes = utf8.encode(body is String ? body : jsonEncode(body ?? {}));
    return http.StreamedResponse(Stream.value(bytes), status, headers: {'content-type': 'application/json'});
  }

  /// Pushes one SSE event to the open connection.
  void emit(String event, Map<String, Object?> data, {int? id, int connection = -1}) {
    final c = openStreams[connection < 0 ? openStreams.length - 1 : connection];
    c.add(utf8.encode('${id != null ? 'id: $id\n' : ''}event: $event\ndata: ${jsonEncode(data)}\n\n'));
  }

  void keepalive() => openStreams.last.add(utf8.encode(':keepalive\n\n'));

  /// Drops the current stream connection like a network failure would.
  Future<void> dropStream() => openStreams.last.close();

  /// An [ApiFactory] for the controller that talks to this server.
  ApiClient client(String baseUrl, String? token) => ApiClient(baseUrl: baseUrl, token: token, httpClient: this, timeout: const Duration(seconds: 5));
  ApiFactory get factory => client;
}

Map<String, Object?> msgJson(int id, {String peer = '106901234', String body = '你好', String direction = 'in', String origin = 'device', String? code, int? readAt, int simSlot = 1, int? replyTo}) => {
      'id': id,
      'deviceId': 'd1',
      'direction': direction,
      'origin': origin,
      'peer': peer,
      'peerKey': peer,
      'body': body,
      'simSlot': simSlot,
      'deviceTime': DateTime(2026, 9, 20, 12).millisecondsSinceEpoch + id * 1000,
      'serverTime': DateTime(2026, 9, 20, 12).millisecondsSinceEpoch,
      'code': ?code,
      'readAt': ?readAt,
      'replyTo': ?replyTo,
    };

Map<String, Object?> convJson(Map<String, Object?> last, {int unread = 0, bool replyable = true}) =>
    {'deviceId': last['deviceId'], 'peer': last['peer'], 'peerKey': last['peerKey'], 'last': last, 'unread': unread, 'replyable': replyable};

Map<String, Object?> phoneJson({String id = 'd1', String name = 'Pixel 7 · 主力机', String effective = 'any', String platform = 'any', String? phonePolicy = 'any', bool online = true}) => {
      'id': id,
      'name': name,
      'sims': [
        {'slot': 1, 'subscriptionId': 3, 'label': '中国移动'},
        {'slot': 2, 'subscriptionId': 4, 'label': '中国联通'},
      ],
      'online': online,
      'revoked': false,
      'sendPolicy': platform,
      'phoneSendPolicy': ?phonePolicy,
      'effectivePolicy': effective,
    };

Map<String, Object?> taskJson({String id = 't_1', String status = 'queued', String body = 'TD', String? error, String mode = 'reply'}) => {
      'taskId': id,
      'deviceId': 'd1',
      'mode': mode,
      'recipient': '106901234',
      'recipientKey': '106901234',
      'body': body,
      'status': status,
      'error': ?error,
      'createdAt': 1,
      'updatedAt': 1,
      'expiresAt': 2,
    };

/// The routes a connected client needs, with sensible defaults. Override what a test cares about.
Map<String, Object? Function(Req)> connectedRoutes({
  List<String> scopes = const ['read', 'reply', 'send'],
  List<Map<String, Object?>>? conversations,
  List<Map<String, Object?>>? phones,
  List<Map<String, Object?>>? messages,
}) =>
    {
      'GET /api/v1/me': (_) => {'deviceId': 'c1', 'kind': 'client', 'name': '台式机', 'scopes': scopes, 'serverVersion': '0.2.0'},
      'GET /api/v1/conversations': (_) => {'items': conversations ?? [], 'unread': (conversations ?? []).fold<int>(0, (n, c) => n + (c['unread'] as int))},
      'GET /api/v1/phones': (_) => {'items': phones ?? [phoneJson()]},
      'GET /api/v1/messages': (_) => {'items': messages ?? []},
      'GET /api/v1/outbound': (_) => {'items': []},
      'POST /api/v1/messages/read': (_) => {'changed': []},
    };
