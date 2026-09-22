import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../session/app_controller.dart';
import '../session/platform_hooks.dart';
import '../session/settings_store.dart';
import '../update/client_updater.dart';

/// Connection settings: the address (with verification), a connection test, notifications, quick replies and signing out.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key, required this.controller});

  final AppController controller;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late final _url = TextEditingController(
    text: widget.controller.settings.serverUrl ?? '',
  );
  late final _quick = TextEditingController(
    text: widget.controller.settings.quickReplies.join('，'),
  );
  String? _urlError;
  ({bool ok, String text})? _note;
  bool _busy = false;
  final _updater = ClientUpdateService();
  ClientUpdateResult _update = const ClientUpdateIdle();
  bool _updateBusy = false;
  String? _updateNote;

  AppController get c => widget.controller;

  @override
  void dispose() {
    _url.dispose();
    _quick.dispose();
    super.dispose();
  }

  Future<void> _saveUrl() async {
    setState(() {
      _busy = true;
      _urlError = null;
      _note = null;
    });
    final error = await c.changeServerUrl(_url.text);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _urlError = error;
      if (error == null) _note = (ok: true, text: '已保存，令牌继续有效。');
    });
  }

  Future<void> _test() async {
    setState(() {
      _busy = true;
      _note = null;
    });
    final text = await c.testConnection();
    if (!mounted) return;
    setState(() {
      _busy = false;
      _note = (ok: text.startsWith('连接正常'), text: text);
    });
  }

  void _saveQuick() {
    final list = _quick.text
        .split(RegExp(r'[,，\n]'))
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .take(8)
        .toList();
    c.updateSettings(
      c.settings.copyWith(
        quickReplies: list.isEmpty ? ClientSettings.defaultQuickReplies : list,
      ),
    );
  }

  Future<void> _checkUpdates() async {
    if (_updateBusy) return;
    setState(() {
      _updateBusy = true;
      _updateNote = null;
      _update = const ClientUpdateChecking();
    });
    final result = await _updater.check(c.appVersion);
    if (!mounted) return;
    setState(() {
      _updateBusy = false;
      _update = result;
    });
  }

  Future<void> _installUpdate(ClientUpdate update) async {
    if (_updateBusy) return;
    setState(() {
      _updateBusy = true;
      _updateNote = '正在下载并校验安装包…';
    });
    final result = await _updater.downloadAndInstall(update);
    if (!mounted) return;
    setState(() {
      _updateBusy = false;
      if (result is ClientInstallStarted) {
        _updateNote = '安装包已校验，已打开系统安装确认。';
      } else if (result is ClientInstallPermissionRequired) {
        _updateNote = '请允许本应用安装未知来源应用，然后再次点击安装。';
      } else if (result is ClientInstallFailed) {
        _updateNote = result.message;
      }
    });
  }

  Widget _updateSection(ThemeData theme) {
    final result = _update;
    late final Widget body;
    if (result is ClientUpdateIdle) {
      body = const Text('可手动检查 GitHub Release 中的最新客户端。');
    } else if (result is ClientUpdateChecking) {
      body = const Text('正在检查客户端更新…');
    } else if (result is ClientUpdateUpToDate) {
      body = Text('当前已是最新版本 v${result.currentVersion}');
    } else if (result is ClientUpdateUnsupported) {
      body = Text(result.reason);
    } else if (result is ClientUpdateFailed) {
      body = Text(result.message, style: TextStyle(color: theme.colorScheme.error));
    } else if (result is ClientUpdateAvailable) {
      final update = result.update;
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('发现新版本 v${update.version}', style: const TextStyle(fontWeight: FontWeight.w600)),
          if (update.releaseNotes.isNotEmpty)
            Text(update.releaseNotes, maxLines: 5, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodySmall),
          Wrap(
            spacing: 8,
            children: [
              FilledButton(
                onPressed: _updateBusy ? null : () => _installUpdate(update),
                child: const Text('下载并安装'),
              ),
              OutlinedButton(onPressed: _updateBusy ? null : _checkUpdates, child: const Text('重新检查')),
            ],
          ),
        ],
      );
    } else {
      body = const SizedBox.shrink();
    }
    final children = <Widget>[body];
    if (_updateNote != null) {
      children.add(Text(_updateNote!, style: theme.textTheme.bodySmall));
    }
    if (_update is! ClientUpdateAvailable && _update is! ClientUpdateChecking) {
      children.add(OutlinedButton(onPressed: _updateBusy ? null : _checkUpdates, child: const Text('检查更新')));
    }
    return _Section('应用更新', children);
  }

  Future<void> _signOut() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('断开连接？'),
        content: const Text('将清除本机的登录令牌，之后需要重新连接才能查看短信。服务器上的短信不受影响。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          TextButton(
            key: const Key('confirmSignOut'),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('断开'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await c.signOut();
    if (mounted) Navigator.of(context).popUntil((r) => r.isFirst);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final s = c.settings;
    final scopes = [
      if (c.scopes.canRead) '查看',
      if (c.scopes.canReply) '回复',
      if (c.scopes.canSend) '新发',
      if (c.scopes.canDelete) '删除',
    ];
    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: ListenableBuilder(
        listenable: c,
        builder: (context, _) => ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _Section('服务器地址', [
              TextField(
                key: const Key('settingsUrl'),
                controller: _url,
                keyboardType: TextInputType.url,
                autocorrect: false,
                decoration: InputDecoration(errorText: _urlError),
                onChanged: (_) => setState(() {
                  _urlError = null;
                  _note = null;
                }),
              ),
              Text(
                '换域名或端口不需要重新连接：令牌和地址无关。新地址只有在那台服务器认得这个客户端时才会保存，输错了也不会被锁在外面。',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              Wrap(
                spacing: 8,
                children: [
                  FilledButton(
                    key: const Key('saveUrl'),
                    style: FilledButton.styleFrom(
                      minimumSize: const Size(0, 40),
                    ),
                    onPressed: _busy || _url.text.trim() == s.serverUrl
                        ? null
                        : _saveUrl,
                    child: const Text('保存并验证'),
                  ),
                  OutlinedButton(
                    key: const Key('testConnection'),
                    onPressed: _busy ? null : _test,
                    child: const Text('测试连接'),
                  ),
                ],
              ),
              if (_note != null)
                Text(
                  _note!.text,
                  key: const Key('settingsNote'),
                  style: TextStyle(
                    color: _note!.ok
                        ? theme.colorScheme.primary
                        : theme.colorScheme.error,
                  ),
                ),
            ]),
            _Section('这个客户端', [
              Text(
                s.deviceName ?? '',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              Text(
                '权限：${scopes.isEmpty ? '无' : scopes.join('、')}（由管理员在 Web 设备页设置）',
              ),
              Text(
                '登录令牌：长期有效，不会自动过期，加密保存在本机。',
                style: theme.textTheme.bodySmall,
              ),
              if (c.me?.serverVersion != null)
                Text(
                  '服务器版本 ${c.me!.serverVersion}',
                  style: theme.textTheme.bodySmall,
                ),
            ]),
            _Section('通知', [
              SwitchListTile(
                key: const Key('notifySwitch'),
                contentPadding: EdgeInsets.zero,
                title: const Text('新短信通知'),
                subtitle: const Text('验证码短信的通知里可以直接复制验证码，也可以直接回复'),
                value: s.notifications,
                onChanged: (v) =>
                    c.updateSettings(s.copyWith(notifications: v)),
              ),
              if (defaultTargetPlatform == TargetPlatform.android)
                SwitchListTile(
                  key: const Key('foregroundNotifySwitch'),
                  contentPadding: EdgeInsets.zero,
                  title: const Text('前台也弹出通知'),
                  subtitle: const Text('应用正在屏幕上时也显示系统通知；是否悬浮显示还受系统通知设置控制'),
                  value: s.foregroundNotifications,
                  onChanged: s.notifications
                      ? (v) => c.updateSettings(
                          s.copyWith(foregroundNotifications: v),
                        )
                      : null,
                ),
              if (defaultTargetPlatform == TargetPlatform.windows)
                SwitchListTile(
                  key: const Key('trayswitch'),
                  contentPadding: EdgeInsets.zero,
                  title: const Text('关闭窗口时留在托盘'),
                  subtitle: const Text('关闭主窗口后继续接收短信并弹出通知；在托盘图标上选择“退出”才会完全关闭'),
                  value: s.minimizeToTray,
                  onChanged: (v) =>
                      c.updateSettings(s.copyWith(minimizeToTray: v)),
                ),
            ]),
            if (c.hooks.launchAtLogin != null || c.hooks.battery != null)
              _Section('后台运行', [
                if (c.hooks.launchAtLogin != null)
                  _LaunchAtLoginSwitch(hook: c.hooks.launchAtLogin!),
                if (c.hooks.battery != null)
                  _BatteryTile(hook: c.hooks.battery!),
              ]),
            _Section('快捷回复', [
              TextField(
                key: const Key('quickField'),
                controller: _quick,
                decoration: const InputDecoration(
                  helperText: '用逗号分隔，最多 8 个。点一下填进回复框，仍需要你确认发送',
                ),
                onSubmitted: (_) => _saveQuick(),
                onEditingComplete: _saveQuick,
              ),
            ]),
            _Section('断开连接', [
              Text(
                '清除本机的令牌。服务器地址和设备名称会保留，重新连接更快。',
                style: theme.textTheme.bodySmall,
              ),
              OutlinedButton(
                key: const Key('signOut'),
                onPressed: _signOut,
                child: Text(
                  '断开并清除令牌',
                  style: TextStyle(color: theme.colorScheme.error),
                ),
              ),
            ]),
            if (_updater.supported) _updateSection(theme),
          ],
        ),
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section(this.title, this.children);

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              title,
              style: theme.textTheme.labelMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 8),
            for (final w in children)
              Padding(padding: const EdgeInsets.only(bottom: 8), child: w),
          ],
        ),
      ),
    );
  }
}

/// Windows: start with Windows, hidden in the tray.
class _LaunchAtLoginSwitch extends StatefulWidget {
  const _LaunchAtLoginSwitch({required this.hook});

  final LaunchAtLogin hook;

  @override
  State<_LaunchAtLoginSwitch> createState() => _LaunchAtLoginSwitchState();
}

class _LaunchAtLoginSwitchState extends State<_LaunchAtLoginSwitch> {
  bool? _on;
  String? _problem;

  @override
  void initState() {
    super.initState();
    widget.hook.isEnabled().then((v) {
      if (mounted) setState(() => _on = v);
    });
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      SwitchListTile(
        key: const Key('launchAtLogin'),
        contentPadding: EdgeInsets.zero,
        title: const Text('开机自启'),
        subtitle: const Text('登录 Windows 后自动在托盘里运行，这样不用打开窗口也能收到新短信通知'),
        value: _on ?? false,
        onChanged: _on == null
            ? null
            : (v) async {
                try {
                  await widget.hook.set(v);
                  if (mounted) setState(() => _on = v);
                } on Object {
                  if (mounted) setState(() => _problem = '设置失败，可能被安全软件拦截');
                }
              },
      ),
      if (_problem != null)
        Text(
          _problem!,
          style: TextStyle(color: Theme.of(context).colorScheme.error),
        ),
    ],
  );
}

/// Android: exempt the app from battery optimisation so the background connection is not stopped.
class _BatteryTile extends StatefulWidget {
  const _BatteryTile({required this.hook});

  final BatteryExemption hook;

  @override
  State<_BatteryTile> createState() => _BatteryTileState();
}

class _BatteryTileState extends State<_BatteryTile> {
  bool? _exempt;

  Future<void> _refresh() async {
    final v = await widget.hook.isExempt();
    if (mounted) setState(() => _exempt = v);
  }

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('后台连接'),
        Text(
          '应用在后台时由一个常驻通知保持与服务器的连接，新短信才能及时通知你。系统的省电策略可能会停掉它，建议允许“不受电池优化限制”；部分国产系统还需要允许自启动和后台运行。',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 8),
        if (_exempt == true)
          Text(
            '已允许不受电池优化限制',
            key: const Key('batteryOk'),
            style: TextStyle(color: theme.colorScheme.primary),
          )
        else
          OutlinedButton(
            key: const Key('batteryRequest'),
            onPressed: () async {
              await widget.hook.request();
              await _refresh();
            },
            child: const Text('允许不受电池优化限制'),
          ),
      ],
    );
  }
}
