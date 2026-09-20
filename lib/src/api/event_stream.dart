/// The live channel (docs/协议.md §6.1): Server-Sent Events over a plain HTTP stream, parsed by hand because
/// `EventSource` cannot send the `Authorization` header. No Flutter imports.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'api_client.dart';
import 'connection.dart';
import 'models.dart';
import 'protocol.dart';

/// One raw SSE event before it is interpreted.
class SseEvent {
  const SseEvent({required this.event, required this.data, this.id});
  final String event;
  final String data;
  final String? id;
}

/// Turns the bytes of an SSE response into events. Handles `\n`, `\r\n` and `\r` line ends, comment lines
/// (`:keepalive`), multi-line `data:` and chunk boundaries that fall anywhere, including inside a UTF-8 character.
Stream<SseEvent> parseSse(Stream<List<int>> bytes) async* {
  var event = '', id = '';
  final data = <String>[];
  var sawId = false;

  await for (final line in bytes.transform(utf8.decoder).transform(const _LineSplitter())) {
    if (line.isEmpty) {
      // A blank line ends the event. Events without data (e.g. only "retry:") are not dispatched.
      if (data.isNotEmpty) yield SseEvent(event: event.isEmpty ? 'message' : event, data: data.join('\n'), id: sawId ? id : null);
      event = '';
      data.clear();
      sawId = false;
      continue;
    }
    if (line.startsWith(':')) continue; // comment / keep-alive
    final colon = line.indexOf(':');
    final field = colon < 0 ? line : line.substring(0, colon);
    var value = colon < 0 ? '' : line.substring(colon + 1);
    if (value.startsWith(' ')) value = value.substring(1);
    switch (field) {
      case 'event':
        event = value;
      case 'data':
        data.add(value);
      case 'id':
        if (!value.contains(String.fromCharCode(0))) {
          id = value;
          sawId = true;
        }
    }
  }
}

/// Splits on \n, \r\n and lone \r, across chunk boundaries.
class _LineSplitter extends StreamTransformerBase<String, String> {
  const _LineSplitter();

  @override
  Stream<String> bind(Stream<String> stream) async* {
    var buffer = '';
    var pendingCr = false;
    await for (final chunk in stream) {
      var text = chunk;
      if (pendingCr) {
        // The previous chunk ended with \r: a following \n belongs to it.
        if (text.startsWith('\n')) text = text.substring(1);
        pendingCr = false;
      }
      buffer += text;
      while (true) {
        final n = buffer.indexOf(RegExp(r'[\r\n]'));
        if (n < 0) break;
        final isCr = buffer[n] == '\r';
        yield buffer.substring(0, n);
        if (isCr && n + 1 >= buffer.length) {
          buffer = '';
          pendingCr = true;
          break;
        }
        buffer = buffer.substring(isCr && buffer[n + 1] == '\n' ? n + 2 : n + 1);
      }
    }
  }
}

enum StreamStatus {
  /// Not running.
  idle,
  connecting,
  live,

  /// Disconnected, retrying. The token is kept: only an explicit "token is dead" answer signs the client out.
  waiting,

  /// The server said the token is dead: the stream stopped, the client must connect again.
  tokenDead,

  /// The token is fine but lacks the `read` permission: nothing to stream.
  forbidden,
}

/// Keeps the event stream open: connects, hands every event to [onEvent], and reconnects forever with backoff.
///
/// A reconnect sends `Last-Event-ID`, so the server replays the messages missed meanwhile (or says "resync" when there
/// were too many). Every (re)connection first reports [ResyncEvent]-like state through [onConnected] so the owner can
/// refetch what happened before the stream existed: a fresh connection is not replayed.
class EventStreamRunner {
  EventStreamRunner({
    required this.client,
    required this.onEvent,
    this.onConnected,
    this.onStatus,
    this.silenceTimeout = const Duration(seconds: 70),
    Future<void> Function(Duration)? pause,
    double Function()? random,
  })  : _pause = pause ?? Future<void>.delayed,
        _random = random ?? math.Random().nextDouble;

  final ApiClient client;
  final void Function(ServerEvent event) onEvent;

  /// Called every time the stream (re)opens, before events flow.
  final void Function()? onConnected;
  final void Function(StreamStatus status)? onStatus;

  /// The server sends a keep-alive every 20 s; this long without any bytes means the connection is dead.
  final Duration silenceTimeout;
  final Future<void> Function(Duration) _pause;
  final double Function() _random;

  String? _lastId;
  bool _running = false;
  StreamSubscription<SseEvent>? _sub;
  Completer<void>? _consuming;
  Completer<void>? _wake;

  StreamStatus _status = StreamStatus.idle;
  StreamStatus get status => _status;

  void _set(StreamStatus s) {
    if (_status == s) return;
    _status = s;
    onStatus?.call(s);
  }

  /// Runs until [stop] is called or the token is rejected.
  Future<void> run() async {
    if (_running) return;
    _running = true;
    var attempt = 0;
    while (_running) {
      _set(StreamStatus.connecting);
      var upFor = Duration.zero;
      try {
        final response = await client.openEvents(lastEventId: _lastId);
        if (!_running) break;
        final opened = DateTime.now();
        _set(StreamStatus.live);
        onConnected?.call();
        try {
          await _consume(response.stream);
        } finally {
          upFor = DateTime.now().difference(opened);
        }
      } on ApiException catch (e) {
        if (e.isTokenDead) {
          _set(StreamStatus.tokenDead);
          _running = false;
          return;
        }
        if (e.code == ErrorCodes.scopeDenied) {
          _set(StreamStatus.forbidden);
          _running = false;
          return;
        }
      } on Object {
        // Dropped connection, silence timeout, parse trouble: reconnect below.
      }
      if (!_running) break;

      // A connection that held for a while was healthy: start the backoff over. One that dropped at once was not.
      if (upFor > const Duration(seconds: 30)) attempt = 0;
      _set(StreamStatus.waiting);
      await _sleep(Backoff.delay(attempt++, _random()));
    }
    _set(StreamStatus.idle);
  }

  Future<void> _consume(Stream<List<int>> bytes) {
    final done = _consuming = Completer<void>();
    _sub = parseSse(bytes.timeout(silenceTimeout, onTimeout: (sink) => sink.addError(TimeoutException('no data from the event stream')))).listen(
      (raw) {
        if (raw.id != null) _lastId = raw.id;
        Object? data;
        try {
          data = jsonDecode(raw.data);
        } on FormatException {
          return; // not ours: ignore, never fatal
        }
        if (data is Map) onEvent(ServerEvent.parse(raw.event, data.cast<String, Object?>()));
      },
      onError: (Object e) {
        if (!done.isCompleted) done.completeError(e);
      },
      onDone: () {
        if (!done.isCompleted) done.complete();
      },
      cancelOnError: true,
    );
    return done.future.whenComplete(() => _sub = null);
  }

  Future<void> _sleep(Duration d) {
    _wake = Completer<void>();
    return Future.any([_pause(d), _wake!.future]);
  }

  /// Reconnects now instead of waiting out the backoff (e.g. the network came back).
  void nudge() {
    if (_wake != null && !_wake!.isCompleted) _wake!.complete();
  }

  void stop() {
    _running = false;
    _sub?.cancel();
    _sub = null;
    // Cancelling the subscription would never complete the read loop on its own.
    if (_consuming != null && !_consuming!.isCompleted) _consuming!.complete();
    nudge();
  }
}
