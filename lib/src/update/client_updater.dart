import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

const updateRepository = 'stevennight/nyasmsforward-client';
const _releaseApi =
    'https://api.github.com/repos/$updateRepository/releases/latest';
const _downloadPrefix =
    'https://github.com/$updateRepository/releases/download/';
const _maxMetadataBytes = 2 * 1024 * 1024;
const _maxChecksumBytes = 1024 * 1024;
const _maxArtifactBytes = 256 * 1024 * 1024;

sealed class ClientUpdateResult {
  const ClientUpdateResult();
}

class ClientUpdateIdle extends ClientUpdateResult {
  const ClientUpdateIdle();
}

class ClientUpdateChecking extends ClientUpdateResult {
  const ClientUpdateChecking();
}

class ClientUpdateUpToDate extends ClientUpdateResult {
  const ClientUpdateUpToDate(this.currentVersion);
  final String currentVersion;
}

class ClientUpdateAvailable extends ClientUpdateResult {
  const ClientUpdateAvailable(this.update);
  final ClientUpdate update;
}

class ClientUpdateUnsupported extends ClientUpdateResult {
  const ClientUpdateUnsupported(this.reason);
  final String reason;
}

class ClientUpdateFailed extends ClientUpdateResult {
  const ClientUpdateFailed(this.message);
  final String message;
}

class ClientUpdate {
  const ClientUpdate({
    required this.currentVersion,
    required this.version,
    required this.releaseName,
    required this.releaseNotes,
    required this.artifactName,
    required this.artifactUrl,
    required this.checksumName,
    required this.checksumUrl,
  });

  final String currentVersion;
  final String version;
  final String releaseName;
  final String releaseNotes;
  final String artifactName;
  final String artifactUrl;
  final String checksumName;
  final String checksumUrl;
}

sealed class ClientInstallResult {
  const ClientInstallResult();
}

class ClientInstallStarted extends ClientInstallResult {
  const ClientInstallStarted();
}

class ClientInstallPermissionRequired extends ClientInstallResult {
  const ClientInstallPermissionRequired();
}

class ClientInstallFailed extends ClientInstallResult {
  const ClientInstallFailed(this.message);
  final String message;
}

class ClientUpdateService {
  ClientUpdateService({http.Client? client, bool? windows, bool? android})
    : _client = client ?? http.Client(),
      _windows = windows ?? Platform.isWindows,
      _android = android ?? Platform.isAndroid;

  final http.Client _client;
  final bool _windows;
  final bool _android;
  static const _installChannel = MethodChannel(
    'app.nya.smsforward.client/updater',
  );

  bool get supported => _windows || _android;

  Future<ClientUpdateResult> check(String currentVersion) async {
    if (!supported) return const ClientUpdateUnsupported('当前平台不支持自动更新');
    final current = StableClientVersion.parse(currentVersion);
    if (current == null) return ClientUpdateFailed('当前版本号无效：$currentVersion');
    try {
      final response = await _client
          .get(
            Uri.parse(_releaseApi),
            headers: const {
              'Accept': 'application/vnd.github+json',
              'X-GitHub-Api-Version': '2022-11-28',
              'User-Agent': 'NyaSmsForward-Client-Updater',
            },
          )
          .timeout(const Duration(seconds: 20));
      if (response.statusCode != 200) {
        return ClientUpdateFailed('GitHub 返回 HTTP ${response.statusCode}');
      }
      if (response.bodyBytes.length > _maxMetadataBytes) {
        return const ClientUpdateFailed('Release 信息过大');
      }
      final release = jsonDecode(utf8.decode(response.bodyBytes));
      if (release is! Map<String, dynamic>) {
        return const ClientUpdateFailed('GitHub 返回的 Release 格式无效');
      }
      if (release['draft'] == true || release['prerelease'] == true) {
        return const ClientUpdateFailed('GitHub 返回了草稿或预发行版本');
      }
      final tag = release['tag_name'] as String?;
      final latest = tag == null
          ? null
          : StableClientVersion.parse(
              tag.startsWith('v') ? tag.substring(1) : '',
            );
      if (tag == null || latest == null) {
        return ClientUpdateFailed('Release 标签不是稳定版本：${tag ?? ''}');
      }
      if (latest.compareTo(current) <= 0) {
        return ClientUpdateUpToDate(currentVersion);
      }

      final version = latest.toString();
      final artifactName = _windows
          ? 'NyaSmsForward-Client_${version}_x64-setup.exe'
          : 'NyaSmsForward-Client_$version.apk';
      final checksumName = '$artifactName.sha256';
      final assets =
          (release['assets'] as List?)
              ?.whereType<Map>()
              .map(
                (asset) =>
                    _ReleaseAsset.fromJson(asset.cast<String, Object?>()),
              )
              .toList() ??
          const <_ReleaseAsset>[];
      final artifact = assets
          .where((asset) => asset.name == artifactName)
          .singleOrNull;
      final checksum = assets
          .where((asset) => asset.name == checksumName)
          .singleOrNull;
      if (artifact == null) {
        return ClientUpdateFailed('最新 Release 没有兼容的安装包：$artifactName');
      }
      if (checksum == null) {
        return ClientUpdateFailed('最新 Release 没有校验文件：$checksumName');
      }
      if (!_trustedAsset(artifact, tag, artifactName) ||
          !_trustedAsset(checksum, tag, checksumName)) {
        return const ClientUpdateFailed('Release 资产地址不属于受信任的仓库');
      }
      if (artifact.size <= 0 || artifact.size > _maxArtifactBytes) {
        return const ClientUpdateFailed('安装包大小不符合安全限制');
      }
      final name = (release['name'] as String?)?.trim();
      return ClientUpdateAvailable(
        ClientUpdate(
          currentVersion: currentVersion,
          version: version,
          releaseName: name == null || name.isEmpty ? tag : name,
          releaseNotes: _truncate((release['body'] as String?) ?? '', 4_000),
          artifactName: artifactName,
          artifactUrl: artifact.url,
          checksumName: checksumName,
          checksumUrl: checksum.url,
        ),
      );
    } on FormatException catch (e) {
      return ClientUpdateFailed('Release 信息解析失败：${e.message}');
    } on Object catch (e) {
      return ClientUpdateFailed('检查更新失败：$e');
    }
  }

  Future<ClientInstallResult> downloadAndInstall(ClientUpdate update) async {
    try {
      final tag = 'v${update.version}';
      if (update.artifactUrl != '$_downloadPrefix$tag/${update.artifactName}' ||
          update.checksumUrl != '$_downloadPrefix$tag/${update.checksumName}') {
        throw const FormatException('安装包地址不是预期的 Release 地址');
      }
      final checksumResponse = await _client
          .get(
            Uri.parse(update.checksumUrl),
            headers: const {'User-Agent': 'NyaSmsForward-Client-Updater'},
          )
          .timeout(const Duration(seconds: 20));
      if (checksumResponse.statusCode != 200) {
        throw FormatException('下载校验文件失败：HTTP ${checksumResponse.statusCode}');
      }
      if (checksumResponse.bodyBytes.length > _maxChecksumBytes) {
        throw const FormatException('校验文件过大');
      }
      final expected = _checksumFor(
        utf8.decode(checksumResponse.bodyBytes),
        update.artifactName,
      );
      if (expected == null) {
        throw FormatException('校验文件中没有找到 ${update.artifactName}');
      }

      final directory = await _updateDirectory(update.version);
      final artifact = File(
        '${directory.path}${Platform.pathSeparator}${update.artifactName}',
      );
      final response = await _client
          .send(
            http.Request('GET', Uri.parse(update.artifactUrl))
              ..headers['User-Agent'] = 'NyaSmsForward-Client-Updater',
          )
          .timeout(const Duration(minutes: 3));
      if (response.statusCode != 200) {
        throw FormatException('下载安装包失败：HTTP ${response.statusCode}');
      }
      if (response.contentLength != null &&
          (response.contentLength! <= 0 ||
              response.contentLength! > _maxArtifactBytes)) {
        throw const FormatException('安装包大小不符合安全限制');
      }
      final output = artifact.openWrite();
      var total = 0;
      await for (final chunk in response.stream) {
        total += chunk.length;
        if (total > _maxArtifactBytes) throw const FormatException('安装包超过大小限制');
        output.add(chunk);
      }
      await output.close();
      if (total == 0) throw const FormatException('安装包为空');
      final digest = sha256.convert(await artifact.readAsBytes()).toString();
      if (digest.toLowerCase() != expected) {
        await artifact.delete();
        throw const FormatException('安装包 SHA-256 校验失败');
      }

      if (_windows) {
        await Process.start(
          artifact.path,
          const [],
          mode: ProcessStartMode.detached,
        );
        exit(0);
      }
      if (_android) {
        try {
          await _installChannel.invokeMethod<void>('installApk', {
            'path': artifact.path,
          });
          return const ClientInstallStarted();
        } on PlatformException catch (e) {
          if (e.code == 'permission_required') {
            return const ClientInstallPermissionRequired();
          }
          throw FormatException(e.message ?? '无法打开系统安装器');
        }
      }
      return const ClientInstallFailed('当前平台不支持自动安装');
    } on Object catch (e) {
      return ClientInstallFailed('更新安装失败：$e');
    }
  }

  bool _trustedAsset(_ReleaseAsset asset, String tag, String name) =>
      asset.name == name && asset.url == '$_downloadPrefix$tag/$name';

  Future<Directory> _updateDirectory(String version) async {
    if (_android) {
      final cachePath = await _installChannel.invokeMethod<String>(
        'updatesCacheDirectory',
      );
      if (cachePath == null || cachePath.isEmpty) {
        throw const FormatException('无法取得应用缓存目录');
      }
      return Directory('$cachePath${Platform.pathSeparator}$version')
        ..createSync(recursive: true);
    }
    return Directory(
      '${Directory.systemTemp.path}${Platform.pathSeparator}nyasmsforward-updates${Platform.pathSeparator}$version',
    )..createSync(recursive: true);
  }

  String? _checksumFor(String text, String fileName) {
    for (final raw in text.split(RegExp(r'\r?\n'))) {
      final fields = raw.trim().split(RegExp(r'\s+'));
      if (fields.length >= 2 &&
          RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(fields[0]) &&
          fields[1].replaceFirst('*', '') == fileName) {
        return fields[0].toLowerCase();
      }
    }
    return null;
  }

  String _truncate(String text, int maxLength) {
    final trimmed = text.trim();
    return trimmed.length <= maxLength
        ? trimmed
        : trimmed.substring(0, maxLength);
  }
}

class _ReleaseAsset {
  const _ReleaseAsset({
    required this.name,
    required this.url,
    required this.size,
  });

  factory _ReleaseAsset.fromJson(Map<String, Object?> json) => _ReleaseAsset(
    name: json['name'] as String? ?? '',
    url: json['browser_download_url'] as String? ?? '',
    size: (json['size'] as num?)?.toInt() ?? 0,
  );

  final String name;
  final String url;
  final int size;
}

class StableClientVersion implements Comparable<StableClientVersion> {
  const StableClientVersion(this.major, this.minor, this.patch);

  factory StableClientVersion._fromMatch(RegExpMatch match) =>
      StableClientVersion(
        int.parse(match.group(1)!),
        int.parse(match.group(2)!),
        int.parse(match.group(3)!),
      );

  static StableClientVersion? parse(String value) {
    final match = RegExp(r'^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$')
        .firstMatch(value);
    return match == null ? null : StableClientVersion._fromMatch(match);
  }

  final int major;
  final int minor;
  final int patch;

  @override
  int compareTo(StableClientVersion other) {
    final majorResult = major.compareTo(other.major);
    if (majorResult != 0) return majorResult;
    final minorResult = minor.compareTo(other.minor);
    return minorResult == 0 ? patch.compareTo(other.patch) : minorResult;
  }

  @override
  String toString() => '$major.$minor.$patch';
}
