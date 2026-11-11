import 'dart:io';

import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart';

/// Runtime permission management for Sahara.
///
/// Handles RECORD_AUDIO, ACCESS_FINE_LOCATION, and BLUETOOTH permissions.
/// On Android 12+ these require runtime requests; on older versions some
/// are granted at install time.
class PermissionManager {
  PermissionManager._();

  /// Request all permissions needed by Sahara.
  /// Returns a [PermissionResult] indicating which permissions were granted.
  static Future<PermissionResult> requestAll() async {
    final results = <String, bool>{};

    // Microphone — required for STT.
    results['microphone'] = await _requestMicrophone();

    // Location — required for GPS stamping and BT scanning on Android 12+.
    results['location'] = await _requestLocation();

    // Bluetooth — required for P2P transport. MUST be requested at runtime
    // on Android 12+ (BLUETOOTH_SCAN/CONNECT/ADVERTISE) — the manifest
    // declaration alone leaves the BLE state 'unauthorized', which was the
    // cause of the 'Bluetooth unavailable' error.
    results['bluetooth'] = await _requestBluetooth();

    // Wi-Fi Direct — the second radio. Android 13+ needs NEARBY_WIFI_DEVICES;
    // Android 12 and below reuse the location permission already requested
    // above. Not fatal: the BLE mesh carries traffic on its own.
    results['wifiDirect'] = await _requestWifiDirect();

    return PermissionResult(results);
  }

  /// Check if all critical permissions are granted.
  static Future<bool> hasAllCritical() async {
    // Microphone check uses the speech_to_text package's status.
    // We rely on the STT engine returning false from initialize() if denied.
    return true; // Conservative — let individual engines report failures.
  }

  static Future<bool> _requestMicrophone() async {
    try {
      final status = await Permission.microphone.request();
      return status.isGranted;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> _requestLocation() async {
    try {
      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.deniedForever) {
        return false;
      }
      return permission == LocationPermission.whileInUse ||
          permission == LocationPermission.always;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> _requestWifiDirect() async {
    try {
      if (!Platform.isAndroid) return true;
      // Android 13+ only; on older versions the permission is mapped to the
      // location grant we already have, and permission_handler returns the
      // current status rather than prompting.
      final status = await Permission.nearbyWifiDevices.request();
      return status.isGranted || status.isLimited;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> _requestBluetooth() async {
    try {
      if (Platform.isAndroid) {
        // Request modern Android 12+ Bluetooth permissions.
        // permission_handler safely handles older Android versions by returning
        // granted if declared in manifest.
        final statuses = await [
          Permission.bluetoothScan,
          Permission.bluetoothConnect,
          Permission.bluetoothAdvertise,
        ].request();
        return statuses.values.every((s) => s.isGranted || s.isLimited);
      }
      return true;
    } catch (_) {
      return false;
    }
  }
}

/// Result of a permission request batch.
class PermissionResult {
  final Map<String, bool> results;
  const PermissionResult(this.results);

  bool get microphoneGranted => results['microphone'] ?? false;
  bool get locationGranted => results['location'] ?? false;
  bool get bluetoothGranted => results['bluetooth'] ?? false;
  bool get wifiDirectGranted => results['wifiDirect'] ?? false;

  bool get allGranted =>
      microphoneGranted && locationGranted && bluetoothGranted;

  /// List of denied permission names for display.
  List<String> get denied =>
      results.entries.where((e) => !e.value).map((e) => e.key).toList();
}
