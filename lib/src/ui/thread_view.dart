import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api/models.dart';
import '../session/app_controller.dart';
import 'format.dart';

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
    Message? codeMessage;
    for (final m in messages.reversed) {
      if (m.code != null && m.code!.isNotEmpty) {
        codeMessage = m;
        break;
      }
    }

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(c.peer, style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold)),
                    Text(phone?.name ?? c.deviceId, style: Theme.of(context).textTheme.bodySmall),
                  ],
                ),
              ),
              if (controller.selectingMessages && messages.isNotEmpty)
                TextButton(
                  key: const Key('selectThreadMessages'),
                  onPressed: controller.selectCurrentThread,
                  child: Text(messages.every((m) => controller.selectedMessageIds.contains(m.id)) ? '取消全选' : '全选'),
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
            itemBuilder: (context, i) => Bubble(message: messages[messages.length - 1 - i], controller: controller),
          ),
        ),
        ReplyBox(controller: controller),
      ],
    );
  }
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: ListTile(
        dense: true,
        title: Text('识别到验证码', style: theme.textTheme.bodySmall),
        subtitle: Text(
          widget.code,
          key: const Key('codeText'),
          style: theme.textTheme.headlineSmall?.copyWith(fontFamily: 'monospace', fontWeight: FontWeight.w800, letterSpacing: 3, color: theme.colorScheme.primary),
        ),
        trailing: FilledButton.tonal(
          key: const Key('copyCode'),
          style: FilledButton.styleFrom(minimumSize: const Size(72, 36)),
          onPressed: () async {
            final ok = await copyText(widget.code);
            if (!mounted) return;
            setState(() => _copied = ok);
            Future<void>.delayed(const Duration(milliseconds: 1500), () {
              if (mounted) setState(() => _copied = false);
            });
          },
          child: Text(_copied ? '已复制 ✓' : '复制'),
        ),
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
    final via = out ? (message.origin == 'device' ? ' · 手机上发出' : ' · 经平台发出') : '';
    final sim = message.simSlot != null ? ' · SIM${message.simSlot}' : '';
    return Align(
      alignment: out ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * 0.8),
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 4),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: out ? theme.colorScheme.primaryContainer : theme.colorScheme.surface,
            border: out ? null : Border.all(color: theme.colorScheme.outlineVariant),
            borderRadius: BorderRadius.circular(12),
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
                      onChanged: (_) => controller.toggleMessageSelection(message.id),
                    ),
                    Flexible(child: SelectableText(message.body)),
                  ],
                )
              else
                SelectableText(message.body),
              const SizedBox(height: 2),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('${clock(message.deviceTime)}$via$sim', style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                  if (!controller.selectingMessages && controller.scopes.canDelete)
                    IconButton(
                      tooltip: '删除这条短信',
                      visualDensity: VisualDensity.compact,
                      iconSize: 16,
                      onPressed: () { controller.toggleMessageSelection(message.id); controller.setMessageSelection(true); },
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
    if (_sending || body.trim().isEmpty || widget.controller.replyBlockedReason != null) return;
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
    if (event is! KeyDownEvent || event.logicalKey != LogicalKeyboardKey.enter) return KeyEventResult.ignored;
    if (HardwareKeyboard.instance.isShiftPressed) return KeyEventResult.ignored; // newline
    if (_text.value.composing.isValid && !_text.value.composing.isCollapsed) return KeyEventResult.ignored; // IME candidate
    _send();
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final theme = Theme.of(context);
    final blocked = controller.replyBlockedReason;
    final phone = controller.selected == null ? null : controller.phoneFor(controller.selected!.deviceId);

    return Material(
      color: theme.scaffoldBackgroundColor,
      child: Container(
        decoration: BoxDecoration(border: Border(top: BorderSide(color: theme.colorScheme.outlineVariant))),
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
              children: [
                for (final q in controller.settings.quickReplies)
                  ActionChip(
                    label: Text(q),
                    onPressed: blocked != null
                        ? null
                        : () {
                            _text.text = q; // fills the box; sending stays a deliberate second step
                            _text.selection = TextSelection.collapsed(offset: q.length);
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
                      buildCounter: (_, {required currentLength, required isFocused, maxLength}) => null,
                      decoration: InputDecoration(hintText: blocked != null ? '无法回复' : '回复这个号码（Enter 发送，Shift+Enter 换行）'),
                      onChanged: (_) => setState(() {}),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  key: const Key('sendReply'),
                  style: FilledButton.styleFrom(minimumSize: const Size(64, 44)),
                  onPressed: blocked != null || _sending || _text.text.trim().isEmpty ? null : _send,
                  child: const Text('发送'),
                ),
              ],
            ),
            if (_problem != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(_problem!, key: const Key('replyProblem'), style: TextStyle(color: theme.colorScheme.error)),
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
      decoration: BoxDecoration(color: theme.colorScheme.primaryContainer, borderRadius: BorderRadius.circular(8)),
      child: Text(text, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onPrimaryContainer)),
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
                Expanded(child: Text(t.body, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodySmall)),
                const SizedBox(width: 8),
                Text(
                  t.summary,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: t.status == TaskStatus.failed || t.status == TaskStatus.expired ? theme.colorScheme.error : theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                if (t.status == TaskStatus.queued)
                  TextButton(onPressed: () => controller.cancelTask(t.taskId), child: const Text('取消')),
              ],
            ),
        ],
      ),
    );
  }
}
