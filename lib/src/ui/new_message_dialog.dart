import 'package:flutter/material.dart';

import '../api/models.dart';
import '../api/protocol.dart';
import '../session/app_controller.dart';

/// "New message": pick a phone and SIM, give a number and a text. Only phones that allow new messages can be used.
class NewMessageDialog extends StatefulWidget {
  const NewMessageDialog({super.key, required this.controller, this.initialDevice});

  final AppController controller;
  final String? initialDevice;

  @override
  State<NewMessageDialog> createState() => _NewMessageDialogState();
}

class _NewMessageDialogState extends State<NewMessageDialog> {
  final _to = TextEditingController();
  final _body = TextEditingController();
  String? _deviceId;
  int? _sim;
  String? _problem;
  bool _sending = false;

  List<Phone> get _phones => widget.controller.phones.where((p) => !p.revoked).toList();

  @override
  void initState() {
    super.initState();
    final phones = _phones;
    final preferred = phones.where((p) => p.id == widget.initialDevice);
    final allowed = phones.where((p) => p.blockedReason(reply: false) == null);
    _deviceId = (preferred.isNotEmpty ? preferred.first : allowed.isNotEmpty ? allowed.first : (phones.isNotEmpty ? phones.first : null))?.id;
  }

  @override
  void dispose() {
    _to.dispose();
    _body.dispose();
    super.dispose();
  }

  Phone? get _phone => _phones.where((p) => p.id == _deviceId).firstOrNull;

  String? get _blocked {
    if (!widget.controller.scopes.canSend) return '这个客户端没有“新发”权限，可以在 Web 的设备页调整';
    if (_phones.isEmpty) return '还没有可用的接收端手机';
    return _phone?.blockedReason(reply: false) ?? (_phone == null ? '找不到这台手机' : null);
  }

  Future<void> _submit() async {
    setState(() {
      _sending = true;
      _problem = null;
    });
    final error = await widget.controller.sendNew(deviceId: _deviceId!, simSlot: _sim, to: _to.text.trim(), body: _body.text);
    if (!mounted) return;
    if (error == null) {
      Navigator.of(context).pop();
    } else {
      setState(() {
        _sending = false;
        _problem = error;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final phone = _phone;
    final blocked = _blocked;
    final ready = blocked == null && _to.text.trim().isNotEmpty && _body.text.trim().isNotEmpty && !_sending;
    return AlertDialog(
      title: const Text('新短信'),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              DropdownButtonFormField<String>(
                key: const Key('newPhone'),
                initialValue: _deviceId,
                decoration: const InputDecoration(labelText: '用哪台手机发'),
                items: [
                  for (final p in _phones)
                    DropdownMenuItem(value: p.id, child: Text('${p.name}（${_policyLabel(p.effectivePolicy)}${p.online ? '' : '，离线'}）')),
                ],
                onChanged: (v) => setState(() {
                  _deviceId = v;
                  _sim = null;
                }),
              ),
              if (phone != null && phone.sims.isNotEmpty) ...[
                const SizedBox(height: 12),
                DropdownButtonFormField<int?>(
                  key: const Key('newSim'),
                  initialValue: _sim,
                  decoration: const InputDecoration(labelText: 'SIM 卡'),
                  items: [
                    const DropdownMenuItem<int?>(value: null, child: Text('手机默认')),
                    for (final s in phone.sims) DropdownMenuItem<int?>(value: s.slot, child: Text(s.title)),
                  ],
                  onChanged: (v) => setState(() => _sim = v),
                ),
              ],
              const SizedBox(height: 12),
              TextField(
                key: const Key('newTo'),
                controller: _to,
                keyboardType: TextInputType.phone,
                decoration: const InputDecoration(labelText: '收件人号码', hintText: '例如 13800000000'),
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: 12),
              TextField(
                key: const Key('newBody'),
                controller: _body,
                minLines: 3,
                maxLines: 6,
                maxLength: 1000,
                decoration: const InputDecoration(labelText: '内容'),
                onChanged: (_) => setState(() {}),
              ),
              if (blocked != null) Text(blocked, key: const Key('newBlocked'), style: TextStyle(color: Theme.of(context).colorScheme.primary)),
              if (_problem != null) Text(_problem!, key: const Key('newProblem'), style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('取消')),
        FilledButton(key: const Key('newSend'), style: FilledButton.styleFrom(minimumSize: const Size(72, 40)), onPressed: ready ? _submit : null, child: const Text('发送')),
      ],
    );
  }
}

String _policyLabel(SendPolicy p) => switch (p) {
      SendPolicy.off => '关闭',
      SendPolicy.reply => '仅回复',
      SendPolicy.any => '允许新发',
    };
