/// Things only some platforms can do, offered to the settings page through small interfaces so that the page stays
/// testable and simply hides what the current platform cannot do.
library;

/// Windows: start the app when the user signs in, hidden in the tray, so notifications work without opening it.
abstract interface class LaunchAtLogin {
  Future<bool> isEnabled();
  Future<void> set(bool enabled);
}

/// Android: being exempt from battery optimisation keeps the background connection from being stopped.
abstract interface class BatteryExemption {
  Future<bool> isExempt();
  Future<void> request();
}

class PlatformHooks {
  const PlatformHooks({this.launchAtLogin, this.battery});

  final LaunchAtLogin? launchAtLogin;
  final BatteryExemption? battery;
}
