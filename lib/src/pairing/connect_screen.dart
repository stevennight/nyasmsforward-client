import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api/server_url.dart';
import 'connect_request.dart';
import 'pair_link.dart';

export 'connect_request.dart';

/// Performs the actual pairing / login and returns a message to show, or null on success.
typedef ConnectHandler = Future<String?> Function(ConnectRequest request);

/// M0 placeholder for the real pairing flow (M2).
Future<String?> notImplementedYet(ConnectRequest request) async => '输入有效。配对与登录将在 M2 实现。';

/// Shown when the client is not connected: server address plus either a one-time pairing code or the admin
/// account. Connecting is a one-time step; the resulting token is long-lived (docs/开发计划.md §3.1).
class ConnectScreen extends StatefulWidget {
  const ConnectScreen({super.key, this.onConnect = notImplementedYet, this.initialUrl, this.initialName, this.notice, this.onScan});

  final ConnectHandler onConnect;

  /// Remembered from an earlier connection: signing out keeps the address and the device name.
  final String? initialUrl;
  final String? initialName;

  /// Something the user should know first, e.g. "the token was revoked, connect again".
  final String? notice;

  /// Scans a pairing QR code (Android). Null hides the button.
  final Future<String?> Function(BuildContext context)? onScan;

  @override
  State<ConnectScreen> createState() => _ConnectScreenState();
}

class _ConnectScreenState extends State<ConnectScreen> {
  late final _url = TextEditingController(text: widget.initialUrl ?? '');
  final _code = TextEditingController();
  final _password = TextEditingController();
  final _totp = TextEditingController();
  late final _name = TextEditingController(text: widget.initialName ?? _defaultDeviceName());

  ConnectMode _mode = ConnectMode.pairingCode;
  String? _urlError, _codeError, _passwordError, _totpError, _message;
  bool _busy = false;

  // The Web console shows the pairing code as "483 920": strip anything that is not a digit *before* limiting the
  // length, so pasting the formatted code works instead of being cut off at 6 characters.
  static final _sixDigits = <TextInputFormatter>[
    FilteringTextInputFormatter.digitsOnly,
    LengthLimitingTextInputFormatter(6),
  ];

  static String _defaultDeviceName() => switch (defaultTargetPlatform) {
        TargetPlatform.android => 'Android 客户端',
        TargetPlatform.windows => 'Windows 客户端',
        _ => '客户端',
      };

  @override
  void dispose() {
    for (final c in [_url, _code, _password, _totp, _name]) {
      c.dispose();
    }
    super.dispose();
  }

  /// Accepts a pairing link (the QR content, docs/协议.md §3.2) pasted or scanned: fills the address and the code.
  bool _applyLink(String text) {
    final link = PairLink.tryParse(text);
    if (link == null) return false;
    setState(() {
      _url.text = link.server;
      _code.text = link.code;
      _mode = ConnectMode.pairingCode;
      _urlError = _codeError = null;
    });
    return true;
  }

  Future<void> _submit() async {
    final urlResult = ServerUrl.validate(_url.text);
    final code = _code.text.replaceAll(RegExp(r'\s'), '');
    final totp = _totp.text.trim();

    String? urlError, codeError, passwordError, totpError;
    String? normalizedUrl;
    switch (urlResult) {
      case ServerUrlInvalid(:final problem):
        urlError = serverUrlProblemText(problem);
      case ServerUrlOk(:final url):
        normalizedUrl = url;
    }
    if (_mode == ConnectMode.pairingCode) {
      if (!RegExp(r'^\d{6}$').hasMatch(code)) codeError = '配对码是 6 位数字';
    } else {
      if (_password.text.isEmpty) passwordError = '请输入管理员密码';
      if (totp.isNotEmpty && !RegExp(r'^\d{6}$').hasMatch(totp)) totpError = '动态验证码是 6 位数字';
    }

    setState(() {
      _urlError = urlError;
      _codeError = codeError;
      _passwordError = passwordError;
      _totpError = totpError;
      _message = null;
    });
    if (normalizedUrl == null || codeError != null || passwordError != null || totpError != null) return;

    setState(() => _busy = true);
    final message = await widget.onConnect(ConnectRequest(
      serverUrl: normalizedUrl,
      mode: _mode,
      deviceName: _name.text.trim().isEmpty ? _defaultDeviceName() : _name.text.trim(),
      pairingCode: _mode == ConnectMode.pairingCode ? code : null,
      password: _mode == ConnectMode.accountLogin ? _password.text : null,
      totp: _mode == ConnectMode.accountLogin && totp.isNotEmpty ? totp : null,
    ));
    if (!mounted) return;
    setState(() {
      _busy = false;
      _message = message;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Center(child: Image.asset('assets/nya_logo.png', width: 72, height: 72, key: const Key('appLogo'))),
                      const SizedBox(height: 8),
                      Center(child: Text('NyaSmsForward', style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700))),
                      const SizedBox(height: 12),
                      Text('连接到服务器', style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold)),
                      if (widget.notice != null) ...[
                        const SizedBox(height: 8),
                        Text(widget.notice!, key: const Key('notice'), style: TextStyle(color: theme.colorScheme.error)),
                      ],
                      const SizedBox(height: 16),
                      TextField(
                        key: const Key('serverUrl'),
                        controller: _url,
                        keyboardType: TextInputType.url,
                        autocorrect: false,
                        decoration: InputDecoration(
                          labelText: '服务器地址',
                          hintText: 'https://sms.example.com',
                          errorText: _urlError,
                        ),
                        onChanged: (v) {
                          if (v.startsWith('nyasmsforward://')) _applyLink(v);
                        },
                      ),
                      if (widget.onScan != null) ...[
                        const SizedBox(height: 8),
                        OutlinedButton.icon(
                          key: const Key('scan'),
                          onPressed: _busy
                              ? null
                              : () async {
                                  final text = await widget.onScan!(context);
                                  if (text == null || !mounted) return;
                                  if (!_applyLink(text)) setState(() => _message = '这不是 NyaSmsForward 的配对二维码');
                                },
                          icon: const Icon(Icons.qr_code_scanner),
                          label: const Text('扫描配对二维码'),
                        ),
                      ],
                      const SizedBox(height: 12),
                      SegmentedButton<ConnectMode>(
                        segments: const [
                          ButtonSegment(value: ConnectMode.pairingCode, label: Text('配对码')),
                          ButtonSegment(value: ConnectMode.accountLogin, label: Text('账号登录')),
                        ],
                        selected: {_mode},
                        onSelectionChanged: (s) => setState(() {
                          _mode = s.first;
                          _message = null;
                        }),
                      ),
                      const SizedBox(height: 12),
                      if (_mode == ConnectMode.pairingCode)
                        TextField(
                          key: const Key('pairingCode'),
                          controller: _code,
                          keyboardType: TextInputType.number,
                          inputFormatters: _sixDigits,
                          decoration: InputDecoration(
                            labelText: '配对码',
                            helperText: '在 Web「设备与客户端」里生成',
                            errorText: _codeError,
                          ),
                        )
                      else ...[
                        TextField(
                          key: const Key('password'),
                          controller: _password,
                          obscureText: true,
                          decoration: InputDecoration(
                            labelText: '管理员密码',
                            helperText: '仅用于换取令牌，不会保存',
                            errorText: _passwordError,
                          ),
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          key: const Key('totp'),
                          controller: _totp,
                          keyboardType: TextInputType.number,
                          inputFormatters: _sixDigits,
                          decoration: InputDecoration(
                            labelText: '动态验证码（已启用 TOTP 时）',
                            errorText: _totpError,
                          ),
                        ),
                      ],
                      const SizedBox(height: 12),
                      TextField(
                        key: const Key('deviceName'),
                        controller: _name,
                        decoration: const InputDecoration(labelText: '设备名称'),
                      ),
                      if (_message != null) ...[
                        const SizedBox(height: 12),
                        Text(_message!, key: const Key('message'), style: TextStyle(color: theme.colorScheme.error)),
                      ],
                      const SizedBox(height: 16),
                      FilledButton(
                        key: const Key('connect'),
                        onPressed: _busy ? null : _submit,
                        child: const Text('连接'),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        '只需连接一次：令牌长期有效、不会自动过期，断网 / 服务器重启会自动重连。只有在 Web 里吊销才需要重新配对。',
                        style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
