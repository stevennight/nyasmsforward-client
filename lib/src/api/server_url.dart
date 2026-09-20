/// Validation of the server address typed on the connect screen (docs/协议.md §2.4):
/// `https://` is required; `http://` is only accepted for localhost and private LAN addresses.
library;

enum ServerUrlProblem { empty, badScheme, badHost, publicHttp }

sealed class ServerUrlResult {
  const ServerUrlResult();
}

/// [url] has no trailing slash. [insecure] is true for http:// LAN / localhost addresses so the UI can warn.
final class ServerUrlOk extends ServerUrlResult {
  const ServerUrlOk(this.url, {required this.insecure});

  final String url;
  final bool insecure;

  @override
  bool operator ==(Object other) => other is ServerUrlOk && other.url == url && other.insecure == insecure;

  @override
  int get hashCode => Object.hash(url, insecure);

  @override
  String toString() => 'ServerUrlOk($url, insecure: $insecure)';
}

final class ServerUrlInvalid extends ServerUrlResult {
  const ServerUrlInvalid(this.problem);

  final ServerUrlProblem problem;

  @override
  bool operator ==(Object other) => other is ServerUrlInvalid && other.problem == problem;

  @override
  int get hashCode => problem.hashCode;

  @override
  String toString() => 'ServerUrlInvalid($problem)';
}

/// Words for an address problem, shown under the address field and in the settings page.
String serverUrlProblemText(ServerUrlProblem p) => switch (p) {
      ServerUrlProblem.empty => '请填写服务器地址',
      ServerUrlProblem.badScheme => '地址需要以 https:// 开头',
      ServerUrlProblem.badHost => '服务器地址格式不正确',
      ServerUrlProblem.publicHttp => '公网地址必须使用 HTTPS（只有 localhost / 局域网地址可以用 http）',
    };

abstract final class ServerUrl {
  static final _hostPattern = RegExp(r'^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$');
  static final _ipv4 = RegExp(r'^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$');

  static ServerUrlResult validate(String input) {
    final raw = input.trim();
    if (raw.isEmpty) return const ServerUrlInvalid(ServerUrlProblem.empty);

    final sep = raw.indexOf('://');
    final scheme = sep < 0 ? '' : raw.substring(0, sep).toLowerCase();
    if (scheme != 'https' && scheme != 'http') return const ServerUrlInvalid(ServerUrlProblem.badScheme);

    final rest = raw.substring(sep + 3);
    final slash = rest.indexOf('/');
    final authority = slash < 0 ? rest : rest.substring(0, slash);

    final colon = authority.lastIndexOf(':');
    final host = colon < 0 ? authority : authority.substring(0, colon);
    final port = colon < 0 ? null : authority.substring(colon + 1);
    final portOk = port == null || (int.tryParse(port) ?? 0) >= 1 && int.parse(port) <= 65535;
    if (host.isEmpty || !_hostPattern.hasMatch(host) || !portOk) {
      return const ServerUrlInvalid(ServerUrlProblem.badHost);
    }

    // Only now is it safe to drop trailing slashes: the authority is non-empty, so "scheme://" survives.
    final url = raw.replaceFirst(RegExp(r'/+$'), '');

    if (scheme == 'http') {
      return _isLocalOrPrivate(host)
          ? ServerUrlOk(url, insecure: true)
          : const ServerUrlInvalid(ServerUrlProblem.publicHttp);
    }
    return ServerUrlOk(url, insecure: false);
  }

  static bool _isLocalOrPrivate(String host) {
    if (host.toLowerCase() == 'localhost') return true;
    final m = _ipv4.firstMatch(host);
    if (m == null) return false;
    final o = [for (var i = 1; i <= 4; i++) int.parse(m.group(i)!)];
    if (o.any((n) => n > 255)) return false;
    return o[0] == 127 || o[0] == 10 || (o[0] == 172 && o[1] >= 16 && o[1] <= 31) || (o[0] == 192 && o[1] == 168);
  }
}
