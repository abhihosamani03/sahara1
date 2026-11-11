import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Wi-Fi Aware (NAN) link — Sahara's third radio.
///
/// Unlike Wi-Fi Direct there is no group owner and no connection prompt: each
/// phone publishes a service, discovers peers, and the framework builds a
/// point-to-point data path to one peer. That makes it work when neither phone
/// can act as an access point, which is the common case on cheap handsets.
///
/// The native side (`WifiAwarePlugin.kt`) does publish/subscribe and the data
/// path; this class only marshals frames and exposes state. Requires Android 10
/// (API 29) — older devices report `unsupported` and the mesh keeps running on
/// BLE and Wi-Fi Direct.
class WifiAwareTransport {
  static const MethodChannel _method = MethodChannel('itantra/wifiaware');
  static const EventChannel _events = EventChannel('itantra/wifiaware/events');

  final _controller = StreamController<Uint8List>.broadcast();
  StreamSubscription? _eventSub;

  bool _running = false;
  bool _supported = true;
  int _peers = 0;
  String _status = 'off';
  String? _lastError;

  /// Inbound frames from NAN peers.
  Stream<Uint8List> get incoming => _controller.stream;

  /// Whether the native side accepted `start`.
  bool get isRunning => _running;

  /// Whether this phone supports Wi-Fi Aware at all.
  bool get isSupported => _supported;

  /// Number of live NAN data paths.
  int get peerCount => _peers;

  /// Compact state string for the UI.
  String get status => _status;

  /// Last platform error, if any.
  String? get lastError => _lastError;

  /// Ask the platform whether NAN exists before trying to start it.
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

  /// Start publishing and subscribing. Returns `false` when unavailable.
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
            debugPrint('WifiAware: event channel error: $e');
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
      debugPrint('WifiAware: start failed: $_lastError');
      _running = false;
      return false;
    }
  }

  /// Send a frame to every NAN peer. Returns the fanout count.
  Future<int> send(Uint8List frame) async {
    if (!_running) throw StateError('Wi-Fi Aware not started');
    try {
      final sent = await _method.invokeMethod<int>('send', {'data': frame}) ?? 0;
      if (sent == 0) throw StateError('No Wi-Fi Aware peers');
      return sent;
    } on PlatformException catch (e) {
      throw StateError('Wi-Fi Aware send failed: ${e.message ?? e.code}');
    }
  }

  Future<void> stop() async {
    if (!_running) return;
    _running = false;
    _peers = 0;
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
      case 'status':
        _status = (event['status'] as String?) ?? _status;
        final peers = event['peers'];
        if (peers is num) _peers = peers.toInt();
      case 'error':
        _lastError = event['message'] as String?;
        debugPrint('WifiAware: $_lastError');
    }
  }
}
