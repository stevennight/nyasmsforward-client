/// What the user typed on the connect screen, already validated.
library;

enum ConnectMode { pairingCode, accountLogin }

/// What the user typed, already validated.
class ConnectRequest {
  const ConnectRequest({
    required this.serverUrl,
    required this.mode,
    required this.deviceName,
    this.pairingCode,
    this.password,
    this.totp,
  });

  final String serverUrl;
  final ConnectMode mode;
  final String deviceName;
  final String? pairingCode;
  final String? password;
  final String? totp;
}
