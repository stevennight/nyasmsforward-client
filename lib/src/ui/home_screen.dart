import 'package:flutter/material.dart';

import '../api/models.dart';
import '../session/app_controller.dart';
import 'format.dart';
import 'new_message_dialog.dart';
import 'recycle_bin_screen.dart';
import 'settings_screen.dart';
import 'thread_view.dart';

/// The connected app: conversations on the left and the open one on the right on a wide window (Windows), one at a
/// time on a phone.
class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key, required this.controller});

  final AppController controller;

  static const _wide = 820.0;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final wide = MediaQuery.sizeOf(context).width >= _wide;
        final selected = controller.selected;
        final showThreadOnly = !wide && selected != null;

        return PopScope(
          // On a phone, Back closes the open conversation before it leaves the app.
          canPop: !showThreadOnly,
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop && showThreadOnly) controller.openConversation(null);
          },
          child: Scaffold(
            appBar: AppBar(
              leading: showThreadOnly
                  ? BackButton(
                      onPressed: () => controller.openConversation(null),
                    )
                  : null,
              title: Text(showThreadOnly ? selected.peer : 'NyaSmsForward'),
              actions: [
                Center(child: LinkIndicator(link: controller.link)),
                if (controller.unread > 0)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Center(
                      child: Badge.count(
                        count: controller.unread,
                        key: const Key('unreadBadge'),
                      ),
                    ),
                  ),
                IconButton(
                  key: const Key('newMessage'),
                  tooltip: '新短信',
                  icon: const Icon(Icons.edit_outlined),
                  onPressed: controller.phones.isEmpty
                      ? null
                      : () => showDialog<void>(
                          context: context,
                          builder: (_) => NewMessageDialog(
                            controller: controller,
                            initialDevice: selected?.deviceId,
                          ),
                        ),
                ),
                IconButton(
                  tooltip: '全部已读',
                  icon: const Icon(Icons.done_all),
                  onPressed: controller.unread > 0
                      ? controller.markAllRead
                      : null,
                ),
                if (controller.scopes.canDelete && (wide || !showThreadOnly))
                  IconButton(
                    key: const Key('toggleConversationSelection'),
                    tooltip: controller.selectingConversations
                        ? '退出会话选择'
                        : '选择会话',
                    icon: Icon(
                      controller.selectingConversations
                          ? Icons.close
                          : Icons.playlist_add_check,
                    ),
                    onPressed: () => controller.setConversationSelection(
                      !controller.selectingConversations,
                    ),
                  ),
                if (selected != null &&
                    controller.scopes.canDelete &&
                    !controller.selectingConversations)
                  IconButton(
                    key: const Key('toggleMessageSelection'),
                    tooltip: controller.selectingMessages ? '退出多选' : '多选删除',
                    icon: Icon(
                      controller.selectingMessages
                          ? Icons.close
                          : Icons.checklist,
                    ),
                    onPressed: () => controller.setMessageSelection(
                      !controller.selectingMessages,
                    ),
                  ),
                if (controller.scopes.canDelete)
                  IconButton(
                    key: const Key('openRecycleBin'),
                    tooltip: '回收站',
                    icon: const Icon(Icons.restore_from_trash_outlined),
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) =>
                            RecycleBinScreen(controller: controller),
                      ),
                    ),
                  ),
                if (controller.selectingMessages &&
                    controller.selectedMessageIds.isNotEmpty)
                  IconButton(
                    key: const Key('deleteSelectedMessages'),
                    tooltip: '删除选中 ${controller.selectedMessageIds.length} 条',
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () => _confirmDelete(context, controller),
                  ),
                if (controller.selectingConversations &&
                    controller.selectedConversations.isNotEmpty)
                  IconButton(
                    key: const Key('deleteSelectedConversations'),
                    tooltip:
                        '删除选中 ${controller.selectedConversations.length} 个会话',
                    icon: const Icon(Icons.delete_sweep_outlined),
                    onPressed: () =>
                        _confirmConversationDelete(context, controller),
                  ),
                IconButton(
                  key: const Key('openSettings'),
                  tooltip: '设置',
                  icon: const Icon(Icons.settings_outlined),
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => SettingsScreen(controller: controller),
                    ),
                  ),
                ),
              ],
            ),
            body: Column(
              children: [
                if (controller.banner != null)
                  BannerStrip(text: controller.banner!),
                Expanded(
                  child: wide
                      ? Row(
                          children: [
                            SizedBox(
                              width: 360,
                              child: ConversationList(controller: controller),
                            ),
                            const VerticalDivider(width: 1),
                            Expanded(child: ThreadView(controller: controller)),
                          ],
                        )
                      : (showThreadOnly
                            ? ThreadView(controller: controller)
                            : ConversationList(controller: controller)),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

Future<void> _confirmDelete(
  BuildContext context,
  AppController controller,
) async {
  final count = controller.selectedMessageIds.length;
  final okay = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('移到回收站？'),
      content: Text('选中的 $count 条短信将保留在回收站 30 天，之后永久删除。'),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: const Text('删除'),
        ),
      ],
    ),
  );
  if (okay != true) {
    return;
  }
  if (!context.mounted) {
    return;
  }
  final error = await controller.deleteSelectedMessages();
  if (!context.mounted) {
    return;
  }
  if (error != null) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error)));
  }
}

Future<void> _confirmConversationDelete(
  BuildContext context,
  AppController controller,
) async {
  final count = controller.selectedConversations.length;
  final okay = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('移除完整会话？'),
      content: Text('选中的 $count 个号码会话及其全部短信将保留在回收站 30 天，之后永久删除。'),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: const Text('删除'),
        ),
      ],
    ),
  );
  if (okay != true) {
    return;
  }
  if (!context.mounted) {
    return;
  }
  final error = await controller.deleteSelectedConversations();
  if (!context.mounted) {
    return;
  }
  if (error != null) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error)));
  }
}

class BannerStrip extends StatelessWidget {
  const BannerStrip({super.key, required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      key: const Key('banner'),
      width: double.infinity,
      color: theme.colorScheme.errorContainer,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Text(
        text,
        style: TextStyle(color: theme.colorScheme.onErrorContainer),
      ),
    );
  }
}

/// A small dot and word for the live channel.
class LinkIndicator extends StatelessWidget {
  const LinkIndicator({super.key, required this.link});

  final LinkState link;

  @override
  Widget build(BuildContext context) {
    final (color, text) = switch (link) {
      LinkState.live => (Colors.green, '已连接'),
      LinkState.connecting => (Colors.amber, '连接中…'),
      LinkState.offline => (Colors.red, '已断开，重连中'),
      LinkState.noReadPermission => (Colors.grey, '无查看权限'),
    };
    return Row(
      key: const Key('link'),
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.circle, size: 10, color: color),
        const SizedBox(width: 4),
        Text(text, style: Theme.of(context).textTheme.labelSmall),
      ],
    );
  }
}

class ConversationList extends StatefulWidget {
  const ConversationList({super.key, required this.controller});

  final AppController controller;

  @override
  State<ConversationList> createState() => _ConversationListState();
}

class _ConversationListState extends State<ConversationList> {
  final _search = TextEditingController();
  bool _unreadOnly = false;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  bool _matches(Conversation c) {
    final q = _search.text.trim().toLowerCase();
    if (_unreadOnly && c.unread == 0) return false;
    return q.isEmpty ||
        c.peer.toLowerCase().contains(q) ||
        c.last.body.toLowerCase().contains(q);
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final items = controller.conversations.where(_matches).toList();
    final theme = Theme.of(context);

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  key: const Key('search'),
                  controller: _search,
                  decoration: const InputDecoration(
                    hintText: '搜索号码 / 内容',
                    prefixIcon: Icon(Icons.search, size: 18),
                  ),
                  onChanged: (_) => setState(() {}),
                ),
              ),
              const SizedBox(width: 8),
              FilterChip(
                label: const Text('未读'),
                selected: _unreadOnly,
                onSelected: (v) => setState(() => _unreadOnly = v),
              ),
            ],
          ),
        ),
        Expanded(
          child: items.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      controller.conversations.isEmpty
                          ? '还没有收到短信。先在 Web 里配对一台接收端手机。'
                          : '没有匹配的会话',
                      key: const Key('emptyList'),
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                )
              : ListView.separated(
                  key: const Key('conversations'),
                  itemCount: items.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (context, i) => ConversationTile(
                    conversation: items[i],
                    phoneName: controller.phoneFor(items[i].deviceId)?.name,
                    selected: controller.selected?.key == items[i].key,
                    selecting: controller.selectingConversations,
                    deleteSelected: controller.selectedConversations
                        .containsKey(items[i].key),
                    onTap: () => controller.selectingConversations
                        ? controller.toggleConversationSelection(items[i])
                        : controller.openConversation(items[i]),
                    onToggle: () =>
                        controller.toggleConversationSelection(items[i]),
                  ),
                ),
        ),
      ],
    );
  }
}

class ConversationTile extends StatelessWidget {
  const ConversationTile({
    super.key,
    required this.conversation,
    required this.selected,
    required this.selecting,
    required this.deleteSelected,
    required this.onTap,
    required this.onToggle,
    this.phoneName,
  });

  final Conversation conversation;
  final bool selected;
  final bool selecting;
  final bool deleteSelected;
  final VoidCallback onTap;
  final VoidCallback onToggle;
  final String? phoneName;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = conversation;
    final last = c.last;
    return ListTile(
      selected: selected || (selecting && deleteSelected),
      onTap: onTap,
      leading: selecting
          ? Checkbox(value: deleteSelected, onChanged: (_) => onToggle())
          : null,
      title: Row(
        children: [
          if (!last.isIncoming) Text('发出 ', style: theme.textTheme.labelSmall),
          Flexible(
            child: Text(
              c.peer,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontWeight: c.unread > 0 ? FontWeight.bold : FontWeight.w500,
              ),
            ),
          ),
          if (last.code != null && last.code!.isNotEmpty) ...[
            const SizedBox(width: 6),
            Text(
              last.code!,
              style: theme.textTheme.labelMedium?.copyWith(
                fontFamily: 'monospace',
                color: theme.colorScheme.primary,
              ),
            ),
          ],
        ],
      ),
      subtitle: Text(last.body, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(clock(last.deviceTime), style: theme.textTheme.labelSmall),
          const SizedBox(height: 2),
          if (c.unread > 0)
            Badge.count(count: c.unread)
          else
            Text(
              phoneName?.split(' · ').first ?? '',
              style: theme.textTheme.labelSmall,
            ),
        ],
      ),
    );
  }
}
