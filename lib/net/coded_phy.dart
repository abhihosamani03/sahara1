import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Bluetooth LE **Coded PHY** (long range) link — a third radio beside BLE 1M
/// and Wi-Fi Direct.
///
/// The `bluetooth_low_energy` plugin has no PHY control, so the sharp end of
/// this lives in `CodedPhyPlugin.kt`: extended advertising on the Coded PHY,
/// a Coded-only scan, and a native GATT client that asks the controller for the
/// long-range PHY. This class only marshals frames and exposes the state.
///
/// Coded PHY trades throughput for sensitivity (S=8 coding, ~4× the range of
/// 1M at the same power), which is why it is used for text frames and
/// breadcrumbs rather than for bulk transfers.
class CodedPhyLink {
  static const MethodChannel _method = MethodChannel('itantra/ble_coded_phy');
  static const EventChannel _events =
      EventChannel('itantra/ble_coded_phy/events');

  final _controller = StreamController<Uint8List>.broadcast();

  StreamSubscription? _eventSub;

  bool _running = false;
  bool _supported = true;
  bool _coded = false;
  int _peers = 0;
  String _status = 'off';
  String? _lastError;

  /// Inbound frames from Coded PHY peers.
  Stream<Uint8List> get incoming => _controller.stream;

  /// Whether this phone's radio supports LE Coded PHY at all.
  bool get isSupported => _supported;

  /// Whether the native side accepted `start`.
  bool get isRunning => _running;

  /// Whether the current link is actually running on the Coded PHY. False means
  /// the controller kept us on 1M, so the range benefit is not in effect.
  bool get isCoded => _coded;

  /// Number of live Coded PHY links.
  int get peerCount => _peers;

  /// Compact state string for the UI.
  String get status => _status;

  /// Last platform error, if any.
  String? get lastError => _lastError;

  /// Ask the native side whether this device can do long-range BLE.
  Future<bool> probe() async {
    if (!Platform.isAndroid) {
      _supported = false;
      _status = 'unsupported';
      return false;
    }
    try {
      final caps = await _method.invokeMapMethod<String, dynamic>(
        'capabilities',
      );
      _supported = caps?['supported'] == true;
      if (!_supported) _status = 'unsupported';
      return _supported;
    } on MissingPluginException {
      _supported = false;
      _status = 'unsupported';
      return false;
    } on PlatformException catch (e) {
      _lastError = e.message ?? e.code;
      _supported = false;
      return false;
    }
  }

  /// Start advertising and scanning on the Coded PHY.
  Future<bool> start() async {
    if (_running) return true;
    if (!Platform.isAndroid) {
      _supported = false;
      _status = 'unsupported';
      return false;
    }

    _eventSub ??= _events.receiveBroadcastStream().listen(
          _onEvent,
          onError: (Object e) {
            debugPrint('CodedPhy: event channel error: $e');
            _status = 'error';
          },
        );

    try {
      final ok = await _method.invokeMethod<bool>('start') ?? false;
      _running = ok;
      if (!ok && _status == 'off') _status = 'unavailable';
      return ok;
    } on MissingPluginException {
      _supported = false;
      _status = 'unsupported';
      return false;
    } on PlatformException catch (e) {
      _lastError = e.message ?? e.code;
      _status = 'unavailable';
      debugPrint('CodedPhy: start failed: $_lastError');
      _running = false;
      return false;
    }
  }

  /// Send a frame to every connected Coded PHY peer. Returns the fanout.
  Future<int> send(Uint8List frame) async {
    if (!_running) throw StateError('Coded PHY link not started');
    try {
      final sent = await _method.invokeMethod<int>('send', {'data': frame}) ?? 0;
      if (sent == 0) throw StateError('No Coded PHY peer');
      return sent;
    } on PlatformException catch (e) {
      throw StateError('Coded PHY send failed: ${e.message ?? e.code}');
    }
  }

  Future<void> stop() async {
    if (!_running) return;
    _running = false;
    _peers = 0;
    _coded = false;
    _status = 'off';
    try {
      await _method.invokeMethod<bool>('stop');
    } catch (_) {}
  }

  Future<void> dispose() async {
    await stop();
    await _eventSub?.cancel();
    _eventSub = null;
    await _controller.close();
  }

  void _onEvent(dynamic event) {
    if (event is! Map) return;
    switch (event['type']) {
      case 'frame':
        final data = event['data'];
        if (data is Uint8List && data.isNotEmpty && !_controller.isClosed) {
          _controller.add(data);
        }
      case 'phy':
        _coded = event['coded'] == true;
      case 'status':
        _status = (event['status'] as String?) ?? _status;
        final peers = event['peers'];
        if (peers is num) _peers = peers.toInt();
        final coded = event['coded'];
        if (coded is bool) _coded = coded;
      case 'error':
        _lastError = event['message'] as String?;
        debugPrint('CodedPhy: $_lastError');
    }
  }
}
