import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Battery and thermal state monitor — ADDITIONAL_FEATURES.md §9.
///
/// Reads the real Android values through the `itantra/device` channel
/// (BatteryManager capacity + charging state, PowerManager thermal status).
/// This is what lets the app degrade gracefully in a disaster: an SOS that
/// drains a 10 % battery in a minute is worse than a beacon that lasts an hour.
///
/// When the channel is unavailable (desktop, tests, a platform without the
/// plugin) the last known values are kept rather than invented — a fabricated
/// "100 %" would silently disable every low-battery safeguard.
class BatteryMonitor extends ChangeNotifier {
  static const MethodChannel _channel = MethodChannel('itantra/device');

  int _level = 100;
  bool _isCharging = false;
  BatteryState _state = BatteryState.unknown;
  ThermalState _thermal = ThermalState.unknown;
  bool _hasReading = false;
  Timer? _pollTimer;

  int get level => _level;
  bool get isCharging => _isCharging;
  BatteryState get batteryState => _state;
  ThermalState get thermalState => _thermal;

  /// Whether a real reading has been received from the platform.
  bool get hasReading => _hasReading;

  /// Whether the device is in a resource-constrained state.
  bool get isConstrained => _hasReading && (_level < 20 || _thermal == ThermalState.critical);

  /// Whether we should reduce ML workload (throttle inference, skip GPS).
  bool get shouldThrottle =>
      _hasReading && (_level < 15 || _thermal == ThermalState.critical);

  /// Human-readable status summary.
  String get statusLabel {
    if (!_hasReading) return 'Battery unknown';
    if (_thermal == ThermalState.critical) return 'Thermal critical';
    if (_thermal == ThermalState.severe) return 'Overheating';
    if (_level < 10) return 'Battery critical';
    if (_level < 20) return 'Low battery';
    return 'OK';
  }

  /// Start polling battery state every 30 seconds.
  void startMonitoring() {
    _poll();
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(const Duration(seconds: 30), (_) => _poll());
  }

  /// Stop monitoring.
  void stopMonitoring() {
    _pollTimer?.cancel();
    _pollTimer = null;
  }

  Future<void> _poll() async {
    try {
      final status =
          await _channel.invokeMapMethod<String, dynamic>('status');
      if (status == null) return;
      final level = (status['level'] as num?)?.toInt();
      if (level == null) return;
      final thermal = _thermalFromName(status['thermal'] as String?);
      final charging = (status['charging'] as bool?) ?? false;
      _level = level.clamp(0, 100);
      _isCharging = charging;
      _state = charging
          ? BatteryState.charging
          : level >= 100
              ? BatteryState.full
              : BatteryState.discharging;
      _thermal = thermal;
      _hasReading = true;
      notifyListeners();
    } on MissingPluginException {
      // Not Android (or the channel is not registered): keep last values.
    } on PlatformException catch (e) {
      debugPrint('[BatteryMonitor] poll failed: ${e.message}');
    } on Exception catch (e) {
      debugPrint('[BatteryMonitor] poll failed: $e');
    }
  }

  /// Force-update from platform data (kept public: it is also the seam tests
  /// and any future iOS/desktop implementation use).
  void updateFromPlatform({
    required int level,
    required bool isCharging,
    required BatteryState state,
    required ThermalState thermal,
  }) {
    _level = level.clamp(0, 100);
    _isCharging = isCharging;
    _state = state;
    _thermal = thermal;
    _hasReading = true;
    notifyListeners();
  }

  static ThermalState _thermalFromName(String? name) => switch (name) {
        'none' => ThermalState.nominal,
        'light' => ThermalState.light,
        'moderate' => ThermalState.moderate,
        'severe' => ThermalState.severe,
        'critical' || 'emergency' || 'shutdown' => ThermalState.critical,
        _ => ThermalState.unknown,
      };

  @override
  void dispose() {
    stopMonitoring();
    super.dispose();
  }
}

enum BatteryState {
  charging,
  discharging,
  full,
  unknown,
}

enum ThermalState {
  nominal,
  light,
  moderate,
  severe,
  critical,
  unknown,
}
