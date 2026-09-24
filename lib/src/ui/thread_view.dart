import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api/models.dart';
import '../session/app_controller.dart';
import 'delete_dialog.dart';
import 'format.dart';
import 'widgets.dart';

/// The sender name of a conversation, from its newest message that carries one.
String? _brandOf(List<Message> messages, String fallback) {
  for (final m in messages.reversed) {
    final b = senderBrand(m.body);
    if (b != null) return b;
  }
  return senderBrand(fallback);
}

/// One conversation: the messages, the latest verification code, the send tasks and the reply box.
class ThreadView extends StatelessWidget {
  const ThreadView({super.key, required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final c = controller.selected;
    if (c == null) return const Center(child: Text('选择一个会话查看内容'));
    final phone = controller.phoneFor(c.deviceId);
    final messages = controller.thread;
    Message? lastIncoming;
    for (final m in messages.reversed) {
      if (m.isIncoming) {
        lastIncoming = m;
        break;
      }
    }
    Message? codeMessage;
    for (final m in messages.reversed) {
      if (m.code != null && m.code!.isNotEmpty) {
        codeMessage = m;
        break;
      }
    }

    return Column(
      children: [
        Container(
          padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surface,
            border: Border(bottom: BorderSide(color: Theme.of(context).colorScheme.outlineVariant)),
          ),
          child: Row(
            children: [
              PeerAvatar(peer: c.peer, brand: _brandOf(messages, c.last.body), size: 38),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _brandOf(messages, c.last.body) ?? c.peer,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleMedium
                          ?.copyWith(fontWeight: FontWeight.w700),
                    ),
                    Text(
                      [
                        if (_brandOf(messages, c.last.body) != null) c.peer,
                        phone?.name ?? c.deviceId,
                      ].join(' · '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              if (controller.scopes.canDelete)
                IconButton(
                  key: const Key('toggleMessageSelection'),
                  tooltip: controller.selectingMessages ? '退出短信选择' : '选择短信',
                  visualDensity: VisualDensity.compact,
                  icon: Icon(
                    controller.selectingMessages
                        ? Icons.close
                        : Icons.checklist,
                  ),
                  onPressed: () => controller.setMessageSelection(
                    !controller.selectingMessages,
                  ),
                ),
              if (!controller.selectingMessages &&
                  lastIncoming != null &&
                  controller.scopes.canRead)
                IconButton(
                  key: const Key('markThreadUnread'),
                  tooltip: '标为未读',
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.mark_email_unread_outlined),
                  onPressed: () =>
                      _markThreadUnread(context, controller, lastIncoming!.id),
                ),
              if (controller.selectingMessages && messages.isNotEmpty)
                TextButton(
                  key: const Key('selectThreadMessages'),
                  onPressed: controller.selectCurrentThread,
                  child: Text(
                    messages.every(
                          (m) => controller.selectedMessageIds.contains(m.id),
                        )
                        ? '取消全选'
                        : '全选',
                  ),
                ),
              if (controller.selectingMessages &&
                  controller.selectedMessageIds.isNotEmpty &&
                  controller.scopes.canDelete)
                IconButton(
                  key: const Key('deleteSelectedMessages'),
                  tooltip: '删除选中短信',
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () => _confirmThreadDelete(context, controller),
                ),
            ],
          ),
        ),
        if (codeMessage != null) CodeCard(code: codeMessage.code!),
        Expanded(
          child: ListView.builder(
            key: const Key('thread'),
            reverse: true,
            padding: const EdgeInsets.all(12),
            itemCount: messages.length,
            itemBuilder: (context, i) => Bubble(
              message: messages[messages.length - 1 - i],
              controller: controller,
            ),
          ),
        ),
        ReplyBox(controller: controller),
      ],
    );
  }
}

Future<void> _markThreadUnread(
  BuildContext context,
  AppController controller,
  int id,
) async {
  final error = await controller.markSelectedMessageUnread(id);
  if (!context.mounted || error == null) return;
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error)));
}

Future<void> _confirmThreadDelete(
  BuildContext context,
  AppController controller,
) async {
  final count = controller.selectedMessageIds.length;
  final deletePhone = await confirmDeleteWithPhoneOption(
    context,
    title: '删除选中的 $count 条短信？',
    message: '短信会移入回收站，30 天内可以恢复。',
  );
  if (deletePhone == null || !context.mounted) return;
  final error = await controller.deleteSelectedMessages(
    deletePhone: deletePhone,
  );
  if (!context.mounted || error == null) return;
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error)));
}

/// The verification code the server recognised, with a one-tap copy.
class CodeCard extends StatefulWidget {
  const CodeCard({super.key, required this.code});

  final String code;

  @override
  State<CodeCard> createState() => _CodeCardState();
}

class _CodeCardState extends State<CodeCard> {
  bool _copied = false;

  Future<void> _copy() async {
    final ok = await copyText(widget.code);
    if (!mounted) return;
    setState(() => _copied = ok);
    Future<void>.delayed(const Duration(milliseconds: 1500), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 10, 12, 2),
      padding: const EdgeInsets.fromLTRB(16, 10, 10, 10),
      decoration: BoxDecoration(
        color: scheme.primaryContainer,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          Icon(Icons.verified_user_outlined, color: scheme.primary, size: 22),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('验证码', style: theme.textTheme.labelSmall?.copyWith(color: scheme.onPrimaryContainer)),
                Text(
                  widget.code,
                  key: const Key('codeText'),
                  style: theme.textTheme.headlineSmall?.copyWith(
                    fontFamily: 'monospace',
                    fontWeight: FontWeight.w800,
                    letterSpacing: 4,
                    color: scheme.primary,
                  ),
                ),
              ],
            ),
          ),
          FilledButton.icon(
            key: const Key('copyCode'),
            style: FilledButton.styleFrom(minimumSize: const Size(88, 40)),
            onPressed: _copy,
            icon: Icon(_copied ? Icons.check : Icons.copy_rounded, size: 18),
            label: Text(_copied ? '已复制' : '复制'),
          ),
        ],
      ),
    );
  }
}

class Bubble extends StatelessWidget {
  const Bubble({super.key, required this.message, required this.controller});

  final Message message;
  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final out = !message.isIncoming;
    final via = out
        ? (message.origin == 'device' ? ' · 手机上发出' : ' · 经平台发出')
        : '';
    final sim = message.simSlot != null ? ' · SIM${message.simSlot}' : '';
    final bodyStyle = theme.textTheme.bodyLarge?.copyWith(
      color: out ? theme.colorScheme.onPrimary : theme.colorScheme.onSurface,
    );
    final metaColor = out
        ? theme.colorScheme.onPrimary.withValues(alpha: .75)
        : theme.colorScheme.onSurfaceVariant;
    return Align(
      alignment: out ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.sizeOf(context).width * 0.8,
        ),
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 4),
          padding: const EdgeInsets.fromLTRB(14, 10, 10, 6),
          decoration: BoxDecoration(
            color: out ? theme.colorScheme.primary : theme.colorScheme.surface,
            border: out
                ? null
                : Border.all(color: theme.colorScheme.outlineVariant),
            borderRadius: BorderRadius.only(
              topLeft: const Radius.circular(18),
              topRight: const Radius.circular(18),
              bottomLeft: Radius.circular(out ? 18 : 4),
              bottomRight: Radius.circular(out ? 4 : 18),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (controller.selectingMessages)
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Checkbox(
                      key: Key('selectMessage_${message.id}'),
                      value: controller.selectedMessageIds.contains(message.id),
                      onChanged: (_) =>
                          controller.toggleMessageSelection(message.id),
                    ),
                    Flexible(child: SelectableText(message.body, style: bodyStyle)),
                  ],
                )
              else
                SelectableText(message.body, style: bodyStyle),
              const SizedBox(height: 2),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '${clock(message.deviceTime)}$via$sim',
                    style: theme.textTheme.labelSmall?.copyWith(color: metaColor),
                  ),
                  if (!controller.selectingMessages &&
                      controller.scopes.canDelete)
                    IconButton(
                      tooltip: '删除这条短信',
                      visualDensity: VisualDensity.compact,
                      iconSize: 16,
                      color: metaColor,
                      constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                      padding: EdgeInsets.zero,
                      onPressed: () {
                        controller.toggleMessageSelection(message.id);
                        controller.setMessageSelection(true);
                      },
                      icon: const Icon(Icons.delete_outline),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Reply box: quick replies, the send tasks of this conversation and the text field. Enter sends, Shift+Enter breaks the
/// line, and Enter that confirms an input-method candidate does neither.
class ReplyBox extends StatefulWidget {
  const ReplyBox({super.key, required this.controller});

  final AppController controller;

  @override
  State<ReplyBox> createState() => _ReplyBoxState();
}

class _ReplyBoxState extends State<ReplyBox> {
  final _text = TextEditingController();
  final _focus = FocusNode();
  String? _problem;
  bool _sending = false;

  @override
  void dispose() {
    _text.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final body = _text.text;
    if (_sending ||
        body.trim().isEmpty ||
        widget.controller.replyBlockedReason != null) {
      return;
    }
    setState(() {
      _sending = true;
      _problem = null;
    });
    final error = await widget.controller.sendReply(body);
    if (!mounted) return;
    setState(() {
      _sending = false;
      _problem = error;
      if (error == null) _text.clear(); // kept on failure, for a retry
    });
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent ||
        event.logicalKey != LogicalKeyboardKey.enter) {
      return KeyEventResult.ignored;
    }
    if (HardwareKeyboard.instance.isShiftPressed) {
      return KeyEventResult.ignored; // newline
    }
    if (_text.value.composing.isValid && !_text.value.composing.isCollapsed) {
      return KeyEventResult.ignored; // IME candidate
    }
    _send();
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final theme = Theme.of(context);
    final blocked = controller.replyBlockedReason;
    final phone = controller.selected == null
        ? null
        : controller.phoneFor(controller.selected!.deviceId);

    return Material(
      color: theme.colorScheme.surface,
      child: Container(
        decoration: BoxDecoration(
          border: Border(
            top: BorderSide(color: theme.colorScheme.outlineVariant),
          ),
        ),
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TaskStrip(controller: controller),
            if (blocked != null)
              _Note(blocked, key: const Key('replyBlocked'))
            else if (phone != null && !phone.online)
              const _Note('手机当前不在线：任务会先排队，手机上线后发出；超过有效期仍未上线则过期。'),
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: [
                for (final q in controller.settings.quickReplies)
                  ActionChip(
                    visualDensity: VisualDensity.compact,
                    avatar: const Icon(Icons.bolt_rounded, size: 16),
                    label: Text(q),
                    onPressed: blocked != null
                        ? null
                        : () {
                            _text.text = q; // fills the box; sending stays a deliberate second step
                            _text.selection = TextSelection.collapsed(
                              offset: q.length,
                            );
                            _focus.requestFocus();
                          },
                  ),
              ],
            ),
            const SizedBox(height: 6),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: Focus(
                    onKeyEvent: _onKey,
                    child: TextField(
                      key: const Key('replyField'),
                      controller: _text,
                      focusNode: _focus,
                      enabled: blocked == null,
                      minLines: 1,
                      maxLines: 4,
                      maxLength: 1000,
                      buildCounter: (
                        _, {
                        required currentLength,
                        required isFocused,
                        maxLength,
                      }) => null,
                      decoration: InputDecoration(
                        hintText: blocked != null
                            ? '无法回复'
                            : '回复短信（Enter 发送，Shift+Enter 换行）',
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(22),
                          borderSide: BorderSide(color: theme.colorScheme.outlineVariant),
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(22),
                          borderSide: BorderSide(color: theme.colorScheme.outlineVariant),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(22),
                          borderSide: BorderSide(color: theme.colorScheme.primary, width: 1.6),
                        ),
                        contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
                      ),
                      onChanged: (_) => setState(() {}),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filled(
                  key: const Key('sendReply'),
                  tooltip: '发送',
                  style: IconButton.styleFrom(minimumSize: const Size(46, 46)),
                  onPressed:
                      blocked != null || _sending || _text.text.trim().isEmpty
                      ? null
                      : _send,
                  icon: const Icon(Icons.send_rounded, size: 20),
                ),
              ],
            ),
            if (_problem != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  _problem!,
                  key: const Key('replyProblem'),
                  style: TextStyle(color: theme.colorScheme.error),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _Note extends StatelessWidget {
  const _Note(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: theme.colorScheme.primaryContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        text,
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onPrimaryContainer,
        ),
      ),
    );
  }
}

/// The latest send tasks of the open conversation and how far they got.
class TaskStrip extends StatelessWidget {
  const TaskStrip({super.key, required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final tasks = controller.tasks;
    if (tasks.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Column(
        key: const Key('tasks'),
        children: [
          for (final t in tasks)
            Row(
              children: [
                Expanded(
                  child: Text(
                    t.body,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  t.summary,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color:
                        t.status == TaskStatus.failed ||
                            t.status == TaskStatus.expired
                        ? theme.colorScheme.error
                        : theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                if (t.status == TaskStatus.queued)
                  TextButton(
                    onPressed: () => controller.cancelTask(t.taskId),
                    child: const Text('取消'),
                  ),
              ],
            ),
        ],
      ),
    );
  }
}
