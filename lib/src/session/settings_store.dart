import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// The client's non-secret settings. The token is NOT here: it lives in the [TokenStore] (Keystore / Credential Manager).
///
/// [serverUrl] and [deviceName] survive signing out, so connecting again is one field shorter. [deviceId] and [scopes]
/// describe the current token and are dropped with it.
class ClientSettings {
  const ClientSettings({
    this.serverUrl,
    this.deviceName,
    this.deviceId,
    this.scopes = const {},
    this.notifications = true,
    this.foregroundNotifications = false,
    this.minimizeToTray = true,
    this.quickReplies = defaultQuickReplies,
  });

  factory ClientSettings.fromJson(Map<String, Object?> j) => ClientSettings(
    serverUrl: j['serverUrl'] as String?,
    deviceName: j['deviceName'] as String?,
    deviceId: j['deviceId'] as String?,
    scopes: {
      for (final s in (j['scopes'] as List?) ?? const [])
        if (s is String) s,
    },
    notifications: j['notifications'] != false,
    foregroundNotifications: j['foregroundNotifications'] == true,
    minimizeToTray: j['minimizeToTray'] != false,
    quickReplies: [
      for (final q in (j['quickReplies'] as List?) ?? defaultQuickReplies)
        if (q is String && q.isNotEmpty) q,
    ],
  );

  static const defaultQuickReplies = ['TD', 'Y', 'N', '1'];

  final String? serverUrl;
  final String? deviceName;
  final String? deviceId;
  final Set<String> scopes;

  /// Show a notification for new messages.
  final bool notifications;

  /// Android: also show a system notification while the app is on screen.
  /// Off by default to preserve the quiet foreground behaviour.
  final bool foregroundNotifications;

  /// Windows: closing the window keeps the app running in the tray.
  final bool minimizeToTray;

  /// One tap fills the reply box (docs/开发计划.md: configurable from the settings page).
  final List<String> quickReplies;

  ClientSettings copyWith({
    String? serverUrl,
    String? deviceName,
    String? deviceId,
    Set<String>? scopes,
    bool? notifications,
    bool? foregroundNotifications,
    bool? minimizeToTray,
    List<String>? quickReplies,
    bool clearIdentity = false,
  }) => ClientSettings(
    serverUrl: serverUrl ?? this.serverUrl,
    deviceName: deviceName ?? this.deviceName,
    deviceId: clearIdentity ? null : (deviceId ?? this.deviceId),
    scopes: clearIdentity ? const {} : (scopes ?? this.scopes),
    notifications: notifications ?? this.notifications,
    foregroundNotifications:
        foregroundNotifications ?? this.foregroundNotifications,
    minimizeToTray: minimizeToTray ?? this.minimizeToTray,
    quickReplies: quickReplies ?? this.quickReplies,
  );

  Map<String, Object?> toJson() => {
    'serverUrl': serverUrl,
    'deviceName': deviceName,
    'deviceId': deviceId,
    'scopes': scopes.toList()..sort(),
    'notifications': notifications,
    'foregroundNotifications': foregroundNotifications,
    'minimizeToTray': minimizeToTray,
    'quickReplies': quickReplies,
  };
}

abstract interface class SettingsStore {
  Future<ClientSettings> load();
  Future<void> save(ClientSettings settings);
}

class PrefsSettingsStore implements SettingsStore {
  static const _key = 'nyasmsforward.settings';

  @override
  Future<ClientSettings> load() async {
    final raw = (await SharedPreferences.getInstance()).getString(_key);
    if (raw == null) return const ClientSettings();
    try {
      return ClientSettings.fromJson(
        (jsonDecode(raw) as Map).cast<String, Object?>(),
      );
    } on Object {
      return const ClientSettings(); // a damaged value must not stop the app from starting
    }
  }

  @override
  Future<void> save(ClientSettings settings) async =>
      (await SharedPreferences.getInstance()).setString(
        _key,
        jsonEncode(settings.toJson()),
      );
}

class MemorySettingsStore implements SettingsStore {
  MemorySettingsStore([this.value = const ClientSettings()]);
  ClientSettings value;

  @override
  Future<ClientSettings> load() async => value;

  @override
  Future<void> save(ClientSettings settings) async => value = settings;
}
