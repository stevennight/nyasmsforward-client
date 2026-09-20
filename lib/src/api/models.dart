/// The shapes the server sends (docs/协议.md). Parsing is forgiving: unknown fields are ignored, and a missing
/// optional field is null, so a newer server never breaks an older client.
library;

import 'protocol.dart';

int? _int(Object? v) => v is num ? v.toInt() : null;
String? _str(Object? v) => v is String ? v : null;

/// One SIM slot of a receiver phone.
class Sim {
  const Sim({required this.slot, this.subscriptionId, this.label});

  factory Sim.fromJson(Map<String, Object?> j) =>
      Sim(slot: _int(j['slot']) ?? 0, subscriptionId: _int(j['subscriptionId']), label: _str(j['label']));

  final int slot;
  final int? subscriptionId;
  final String? label;

  String get title => label == null || label!.isEmpty ? 'SIM$slot' : 'SIM$slot · $label';
}

enum Direction { incoming, outgoing }

/// One SMS of a conversation.
class Message {
  const Message({
    required this.id,
    required this.deviceId,
    required this.direction,
    required this.origin,
    required this.peer,
    required this.peerKey,
    required this.body,
    required this.deviceTime,
    this.simSlot,
    this.replyTo,
    this.code,
    this.readAt,
    this.backfill = false,
  });

  factory Message.fromJson(Map<String, Object?> j) => Message(
        id: _int(j['id']) ?? 0,
        deviceId: _str(j['deviceId']) ?? '',
        direction: j['direction'] == 'out' ? Direction.outgoing : Direction.incoming,
        origin: _str(j['origin']) ?? 'device',
        peer: _str(j['peer']) ?? '',
        peerKey: _str(j['peerKey']) ?? '',
        body: _str(j['body']) ?? '',
        simSlot: _int(j['simSlot']),
        replyTo: _int(j['replyTo']),
        deviceTime: _int(j['deviceTime']) ?? 0,
        code: _str(j['code']),
        readAt: _int(j['readAt']),
        backfill: j['backfill'] == true,
      );

  final int id;
  final String deviceId;
  final Direction direction;

  /// `device` (reported by the phone) or `platform` (sent through a task).
  final String origin;
  final String peer;
  final String peerKey;
  final String body;
  final int? simSlot;
  final int? replyTo;
  final int deviceTime;

  /// The verification code the server found in the text, if any.
  final String? code;
  final int? readAt;
  final bool backfill;

  bool get isIncoming => direction == Direction.incoming;
  bool get isUnread => isIncoming && readAt == null;

  Message copyWith({int? readAt}) => Message(
        id: id,
        deviceId: deviceId,
        direction: direction,
        origin: origin,
        peer: peer,
        peerKey: peerKey,
        body: body,
        deviceTime: deviceTime,
        simSlot: simSlot,
        replyTo: replyTo,
        code: code,
        readAt: readAt ?? this.readAt,
        backfill: backfill,
      );
}

/// A thread with one number through one receiver phone.
class Conversation {
  const Conversation({
    required this.deviceId,
    required this.peer,
    required this.peerKey,
    required this.last,
    required this.unread,
    required this.replyable,
  });

  factory Conversation.fromJson(Map<String, Object?> j) => Conversation(
        deviceId: _str(j['deviceId']) ?? '',
        peer: _str(j['peer']) ?? '',
        peerKey: _str(j['peerKey']) ?? '',
        last: Message.fromJson((j['last'] as Map?)?.cast<String, Object?>() ?? const {}),
        unread: _int(j['unread']) ?? 0,
        replyable: j['replyable'] != false,
      );

  final String deviceId;
  final String peer;
  final String peerKey;
  final Message last;
  final int unread;

  /// False for alphanumeric sender ids ("示例银行"), which cannot be replied to.
  final bool replyable;

  String get key => '$deviceId|$peerKey';
}

/// A receiver phone as clients see it (GET /api/v1/phones).
class Phone {
  const Phone({
    required this.id,
    required this.name,
    required this.sims,
    required this.online,
    required this.revoked,
    required this.sendPolicy,
    required this.effectivePolicy,
    this.phoneSendPolicy,
    this.battery,
  });

  factory Phone.fromJson(Map<String, Object?> j) => Phone(
        id: _str(j['id']) ?? '',
        name: _str(j['name']) ?? '',
        sims: [for (final s in (j['sims'] as List?) ?? const []) if (s is Map) Sim.fromJson(s.cast<String, Object?>())],
        online: j['online'] == true,
        revoked: j['revoked'] == true,
        sendPolicy: SendPolicy.fromWire(_str(j['sendPolicy'])),
        phoneSendPolicy: j['phoneSendPolicy'] == null ? null : SendPolicy.fromWire(_str(j['phoneSendPolicy'])),
        effectivePolicy: SendPolicy.fromWire(_str(j['effectivePolicy'])),
        battery: _int(j['battery']),
      );

  final String id;
  final String name;
  final List<Sim> sims;
  final bool online;
  final bool revoked;
  final SendPolicy sendPolicy;
  final SendPolicy? phoneSendPolicy;

  /// The stricter of the platform policy and what the phone itself reported.
  final SendPolicy effectivePolicy;
  final int? battery;

  /// Why sending in [mode] is not possible, or null when it is (same wording as the web console).
  String? blockedReason({required bool reply}) {
    if (revoked) return '这台手机的令牌已吊销，需要先重新配对';
    final need = reply ? SendPolicy.reply : SendPolicy.any;
    if (effectivePolicy.index >= need.index) return null;
    String label(SendPolicy? p) => switch (p) {
          SendPolicy.off => '关闭',
          SendPolicy.reply => '仅回复',
          SendPolicy.any => '允许新发',
          null => '手机尚未上报',
        };
    return '下发策略不允许${reply ? '回复' : '新发'}（平台：${label(sendPolicy)}；手机：${label(phoneSendPolicy)}）';
  }
}

enum TaskStatus {
  queued,
  dispatched,
  sent,
  delivered,
  failed,
  expired;

  static TaskStatus fromWire(String? v) => TaskStatus.values.firstWhere((s) => s.name == v, orElse: () => TaskStatus.queued);

  bool get isFinal => this == delivered || this == failed || this == expired;
}

/// A send task: a reply to a received message, or a new message.
class OutboundTask {
  const OutboundTask({
    required this.taskId,
    required this.deviceId,
    required this.mode,
    required this.recipient,
    required this.recipientKey,
    required this.body,
    required this.status,
    required this.createdAt,
    this.error,
    this.messageId,
    this.simSlot,
  });

  factory OutboundTask.fromJson(Map<String, Object?> j) => OutboundTask(
        taskId: _str(j['taskId']) ?? '',
        deviceId: _str(j['deviceId']) ?? '',
        mode: _str(j['mode']) ?? 'reply',
        recipient: _str(j['recipient']) ?? '',
        recipientKey: _str(j['recipientKey']) ?? '',
        body: _str(j['body']) ?? '',
        status: TaskStatus.fromWire(_str(j['status'])),
        createdAt: _int(j['createdAt']) ?? 0,
        error: (_str(j['error']) ?? '').isEmpty ? null : _str(j['error']),
        messageId: _int(j['messageId']),
        simSlot: _int(j['simSlot']),
      );

  final String taskId;
  final String deviceId;
  final String mode;
  final String recipient;
  final String recipientKey;
  final String body;
  final TaskStatus status;
  final int createdAt;
  final String? error;
  final int? messageId;
  final int? simSlot;

  /// One line for the task strip, in the words the web console uses.
  String get summary {
    const labels = {
      TaskStatus.queued: '排队中（等待手机上线）',
      TaskStatus.dispatched: '已下发',
      TaskStatus.sent: '已发送',
      TaskStatus.delivered: '已送达',
      TaskStatus.failed: '失败',
      TaskStatus.expired: '已过期',
    };
    final base = labels[status]!;
    final reason = error == null ? null : (taskErrorLabels[error] ?? error);
    return reason != null && (status == TaskStatus.failed || status == TaskStatus.expired) ? '$base：$reason' : base;
  }
}

/// Why a send task failed (docs/协议.md §6.2).
const taskErrorLabels = {
  'policy_denied': '手机的下发策略不允许',
  'recipient_not_recent': '收件人不在手机的“最近来信号码”里',
  'rate_limited': '手机端限速',
  'expired': '任务过期，手机没有及时处理',
  'no_permission': '手机没有授予发送短信权限',
  'sim_unavailable': '该 SIM 卡槽当前没有卡',
  'radio_error': '发送失败（基站 / 网络）',
  'delivery_failed': '已发出，但运营商回报对方没有收到',
  'cancelled': '已取消',
};

/// GET /api/v1/me
class Me {
  const Me({required this.deviceId, required this.kind, required this.name, required this.scopes, this.serverVersion, this.minClientVersion});

  factory Me.fromJson(Map<String, Object?> j) => Me(
        deviceId: _str(j['deviceId']) ?? '',
        kind: _str(j['kind']) ?? '',
        name: _str(j['name']) ?? '',
        scopes: Scopes.fromWire(j['scopes'] as List?),
        serverVersion: _str(j['serverVersion']),
        minClientVersion: _str(j['minClientVersion']),
      );

  final String deviceId;
  final String kind;
  final String name;
  final Scopes scopes;
  final String? serverVersion;
  final String? minClientVersion;
}

/// Events of GET /api/v1/events (docs/协议.md §6.1). Unknown types become [UnknownEvent], never an error.
sealed class ServerEvent {
  const ServerEvent();

  static ServerEvent parse(String type, Map<String, Object?> data) => switch (type) {
        'message' => MessageEvent(Message.fromJson(data), notify: data['notify'] == true),
        'read' => ReadEvent([for (final i in (data['ids'] as List?) ?? const []) if (i is num) i.toInt()]),
        'deleted' => DeletedEvent([for (final i in (data['ids'] as List?) ?? const []) if (i is num) i.toInt()]),
        'outbound' => OutboundEvent(
            taskId: _str(data['taskId']) ?? '',
            deviceId: _str(data['deviceId']) ?? '',
            status: TaskStatus.fromWire(_str(data['status'])),
            error: _str(data['error']),
            messageId: _int(data['messageId']),
          ),
        'device' => DeviceEvent(deviceId: _str(data['deviceId']) ?? '', online: data['online'] == true, battery: _int(data['battery'])),
        'resync' => const ResyncEvent(),
        _ => const UnknownEvent(),
      };
}

class MessageEvent extends ServerEvent {
  const MessageEvent(this.message, {required this.notify});

  final Message message;

  /// Whether to alert the user. False for replies sent through the platform, history backfill and anything already read.
  final bool notify;
}

class ReadEvent extends ServerEvent {
  const ReadEvent(this.ids);
  final List<int> ids;
}

class DeletedEvent extends ServerEvent {
  const DeletedEvent(this.ids);
  final List<int> ids;
}

class OutboundEvent extends ServerEvent {
  const OutboundEvent({required this.taskId, required this.deviceId, required this.status, this.error, this.messageId});
  final String taskId;
  final String deviceId;
  final TaskStatus status;
  final String? error;
  final int? messageId;
}

class DeviceEvent extends ServerEvent {
  const DeviceEvent({required this.deviceId, required this.online, this.battery});
  final String deviceId;
  final bool online;
  final int? battery;
}

class ResyncEvent extends ServerEvent {
  const ResyncEvent();
}

class UnknownEvent extends ServerEvent {
  const UnknownEvent();
}
