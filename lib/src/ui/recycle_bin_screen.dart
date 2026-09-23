import 'package:flutter/material.dart';

import '../api/api_client.dart';
import '../api/models.dart';
import '../session/app_controller.dart';
import 'format.dart';

/// A full screen recycle-bin list. Pages are fetched with the server cursor so a large bin never becomes a modal
/// containing an unbounded response.
class RecycleBinScreen extends StatefulWidget {
  const RecycleBinScreen({super.key, required this.controller});

  final AppController controller;

  @override
  State<RecycleBinScreen> createState() => _RecycleBinScreenState();
}

class _RecycleBinScreenState extends State<RecycleBinScreen> {
  final _items = <Message>[];
  int? _before;
  int? _beforeAt;
  bool _hasMore = true;
  bool _loading = false;
  bool _loadingMore = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load(reset: true);
  }

  Future<void> _load({required bool reset}) async {
    if (reset) {
      if (_loading) return;
      setState(() {
        _loading = true;
        _error = null;
        _before = null;
        _beforeAt = null;
        _hasMore = true;
        _items.clear();
      });
    } else {
      if (_loadingMore || !_hasMore) return;
      setState(() {
        _loadingMore = true;
        _error = null;
      });
    }
    try {
      final page = await widget.controller.deletedMessages(
        before: _before,
        beforeAt: _beforeAt,
      );
      if (!mounted) return;
      setState(() {
        final seen = _items.map((m) => m.id).toSet();
        _items.addAll(page.items.where((m) => seen.add(m.id)));
        _hasMore = page.items.length >= ApiClient.recyclePage;
        if (page.items.isNotEmpty) {
          _before = page.items.last.id;
          _beforeAt = page.items.last.deletedAt;
        }
        _loading = false;
        _loadingMore = false;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.text;
        _loading = false;
        _loadingMore = false;
      });
    }
  }

  Future<void> _restore(Message message) async {
    final error = await widget.controller.restoreMessage(message.id);
    if (!mounted) return;
    if (error != null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(error)));
      return;
    }
    setState(() => _items.removeWhere((m) => m.id == message.id));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('短信回收站'),
        actions: [
          IconButton(
            tooltip: '刷新',
            onPressed: _loading ? null : () => _load(reset: true),
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: () => _load(reset: true),
              child: _items.isEmpty
                  ? ListView(
                      children: const [
                        SizedBox(height: 180),
                        Center(child: Text('回收站为空。删除的短信保留 30 天。')),
                      ],
                    )
                  : ListView.separated(
                      key: const Key('recycleMessages'),
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      itemCount: _items.length + (_hasMore ? 1 : 0),
                      separatorBuilder: (_, _) => const Divider(height: 1),
                      itemBuilder: (context, index) {
                        if (index == _items.length) {
                          return Padding(
                            padding: const EdgeInsets.all(16),
                            child: Center(
                              child: _loadingMore
                                  ? const CircularProgressIndicator()
                                  : OutlinedButton(
                                      onPressed: () => _load(reset: false),
                                      child: const Text('加载更早的短信'),
                                    ),
                            ),
                          );
                        }
                        final message = _items[index];
                        return RecycleMessageTile(
                          message: message,
                          onRestore: () => _restore(message),
                        );
                      },
                    ),
            ),
      bottomNavigationBar: _error == null
          ? null
          : Material(
              color: Theme.of(context).colorScheme.errorContainer,
              child: SafeArea(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(_error!),
                ),
              ),
            ),
    );
  }
}

class RecycleMessageTile extends StatelessWidget {
  const RecycleMessageTile({
    super.key,
    required this.message,
    required this.onRestore,
  });

  final Message message;
  final VoidCallback onRestore;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      title: Row(
        children: [
          Expanded(
            child: Text(
              message.peer,
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
          ),
          Text(clock(message.deviceTime), style: theme.textTheme.labelSmall),
        ],
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 3),
          Text(message.body, maxLines: 3, overflow: TextOverflow.ellipsis),
          const SizedBox(height: 3),
          Text(
            '${message.isIncoming ? '收到' : '发出'} · 删除于 ${message.deletedAt == null ? '刚刚' : clock(message.deletedAt!)} · 保留 30 天',
            style: theme.textTheme.labelSmall,
          ),
        ],
      ),
      trailing: TextButton(onPressed: onRestore, child: const Text('恢复')),
    );
  }
}
