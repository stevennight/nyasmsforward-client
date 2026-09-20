import 'dart:async';
import 'dart:convert';

import 'package:client/src/api/event_stream.dart';
import 'package:client/src/api/models.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_server.dart';

Stream<List<int>> chunks(List<String> parts) => Stream.fromIterable(parts.map(utf8.encode));

void main() {
  group('SSE parser', () {
    test('reads events with id, type and JSON data, skipping keep-alive comments', () async {
      final events = await parseSse(chunks([
        ': hello\n\n',
        'retry: 3000\n\n',
        'id: 1042\nevent: message\ndata: {"id":1042}\n\n',
        ':keepalive\n\n',
        'event: read\ndata: {"ids":[1]}\n\n',
      ])).toList();
      expect(events.map((e) => (e.event, e.id, e.data)), [('message', '1042', '{"id":1042}'), ('read', null, '{"ids":[1]}')]);
    });

    test('handles CRLF and CR line ends and chunks that split anywhere', () async {
      final wire = 'id: 7\r\nevent: message\r\ndata: {"a":1}\r\n\r\nevent: x\rdata: y\r\r';
      final bytes = utf8.encode(wire);
      // One byte at a time is the worst case for boundaries.
      final events = await parseSse(Stream.fromIterable([for (final b in bytes) [b]])).toList();
      expect(events.map((e) => (e.event, e.id, e.data)), [('message', '7', '{"a":1}'), ('x', null, 'y')]);
    });

    test('a multi-byte character split across chunks survives', () async {
      final bytes = utf8.encode('event: message\ndata: {"body":"验证码🙂"}\n\n');
      for (var cut = 1; cut < bytes.length; cut++) {
        final events = await parseSse(Stream.fromIterable([bytes.sublist(0, cut), bytes.sublist(cut)])).toList();
        expect(events.single.data, '{"body":"验证码🙂"}', reason: 'cut at $cut');
      }
    });

    test('multiple data lines join with a newline, and an event without data is not dispatched', () async {
      final events = await parseSse(chunks(['data: a\ndata: b\n\n', 'event: lonely\n\n'])).toList();
      expect(events.single.data, 'a\nb');
    });
  });

  group('event interpretation', () {
    test('a message event carries the notify flag', () {
      final e = ServerEvent.parse('message', {...msgJson(5, code: '583921'), 'notify': true});
      expect(e, isA<MessageEvent>().having((m) => m.notify, 'notify', true).having((m) => m.message.code, 'code', '583921'));
      expect((ServerEvent.parse('message', {...msgJson(5), 'notify': false}) as MessageEvent).notify, isFalse);
      expect((ServerEvent.parse('message', msgJson(5)) as MessageEvent).notify, isFalse, reason: 'no flag means no alert');
    });

    test('the other event types', () {
      expect(ServerEvent.parse('read', {'ids': [1, 2]}), isA<ReadEvent>().having((e) => e.ids, 'ids', [1, 2]));
      expect(ServerEvent.parse('deleted', {'ids': [3]}), isA<DeletedEvent>());
      expect(ServerEvent.parse('resync', {}), isA<ResyncEvent>());
      expect(ServerEvent.parse('device', {'deviceId': 'd1', 'online': true, 'battery': 80}), isA<DeviceEvent>().having((e) => e.battery, 'battery', 80));
      expect(
        ServerEvent.parse('outbound', {'taskId': 't', 'deviceId': 'd1', 'status': 'delivered', 'error': ''}),
        isA<OutboundEvent>().having((e) => e.status, 'status', TaskStatus.delivered),
      );
    });
  });

  group('EventStreamRunner', () {
    late FakeServer server;
    late List<ServerEvent> events;
    late List<StreamStatus> statuses;
    late List<Duration> pauses;
    late int connected;

    EventStreamRunner runner({Duration silence = const Duration(seconds: 70)}) {
      final r = EventStreamRunner(
        client: server.client('https://sms.example.com', 'nsf_tok'),
        onEvent: events.add,
        onConnected: () => connected++,
        onStatus: statuses.add,
        silenceTimeout: silence,
        // No real waiting: record the delay and carry on.
        pause: (d) async => pauses.add(d),
        random: () => 0,
      );
      return r;
    }

    setUp(() {
      server = FakeServer();
      events = [];
      statuses = [];
      pauses = [];
      connected = 0;
    });

    Future<void> until(bool Function() cond) async {
      for (var i = 0; i < 400 && !cond(); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(cond(), isTrue);
    }

    test('connects with the token in the header, streams events and reconnects with Last-Event-ID', () async {
      final r = runner();
      final done = r.run();
      await until(() => server.openStreams.length == 1);
      expect(server.streamRequests.first.headers['Authorization'], 'Bearer nsf_tok');
      expect(server.streamRequests.first.headers['Accept'], 'text/event-stream');
      expect(server.streamRequests.first.headers.containsKey('Last-Event-ID'), isFalse, reason: 'a first connection has nothing to resume');
      expect(server.streamRequests.first.uri.query, isEmpty);

      server.emit('message', {...msgJson(1041), 'notify': true}, id: 1041);
      server.emit('device', {'deviceId': 'd1', 'online': true});
      server.emit('message', {...msgJson(1042), 'notify': true}, id: 1042);
      await until(() => events.length == 3);
      expect(events.whereType<MessageEvent>().map((e) => e.message.id), [1041, 1042]);
      expect(connected, 1);

      await server.dropStream(); // the network dropped
      await until(() => server.openStreams.length == 2);
      expect(server.streamRequests.last.headers['Last-Event-ID'], '1042', reason: 'only message events carry an id, and the last one is resumed');
      expect(pauses, [const Duration(seconds: 1)]);
      expect(connected, 2);

      r.stop();
      await done;
      expect(r.status, StreamStatus.idle);
    });

    test('keeps retrying with growing delays while the server is down, and never gives up the token', () async {
      final r = runner();
      server.streamFailure = (status: 503, body: '');
      server.streamFailure = (status: 502, body: '');
      server.streamFailure = (status: 500, body: '');
      final done = r.run();
      await until(() => server.openStreams.isNotEmpty); // the fourth attempt gets through
      expect(pauses, [const Duration(seconds: 1), const Duration(seconds: 2), const Duration(seconds: 4)]);
      expect(statuses, isNot(contains(StreamStatus.tokenDead)));
      expect(statuses.where((s) => s == StreamStatus.waiting), hasLength(3));
      expect(r.status, StreamStatus.live);
      r.stop();
      await done;
    });

    test('a bare 401 from a proxy does not sign the client out', () async {
      final r = runner();
      server.streamFailure = (status: 401, body: '<html>auth required</html>');
      final done = r.run();
      await until(() => pauses.isNotEmpty);
      expect(r.status, isNot(StreamStatus.tokenDead));
      r.stop();
      await done;
    });

    test('401 token_revoked stops the stream and reports the dead token', () async {
      final r = runner();
      server.streamFailure = (status: 401, body: '{"error":"token_revoked"}');
      await r.run();
      expect(r.status, StreamStatus.tokenDead);
      expect(pauses, isEmpty, reason: 'no retry after an explicit revocation');
    });

    test('403 scope_denied means "no read permission", not a connection problem', () async {
      final r = runner();
      server.streamFailure = (status: 403, body: '{"error":"scope_denied"}');
      await r.run();
      expect(r.status, StreamStatus.forbidden);
    });

    test('a connection that goes silent is treated as dead and reconnected', () async {
      final r = runner(silence: const Duration(milliseconds: 60));
      final done = r.run();
      await until(() => server.openStreams.length == 1);
      server.keepalive();
      // ... and then nothing: no keep-alive, no data.
      await until(() => server.openStreams.length == 2);
      expect(pauses, isNotEmpty);
      r.stop();
      await done;
    });

    test('garbage events are ignored, never fatal', () async {
      final r = runner();
      final done = r.run();
      await until(() => server.openStreams.length == 1);
      server.openStreams.last.add(utf8.encode('event: message\ndata: not json\n\n'));
      server.openStreams.last.add(utf8.encode('event: from_the_future\ndata: {"x":1}\n\n'));
      server.emit('read', {'ids': [9]});
      await until(() => events.whereType<ReadEvent>().isNotEmpty);
      expect(events.whereType<UnknownEvent>(), hasLength(1));
      r.stop();
      await done;
    });
  });
}
