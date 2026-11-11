import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Wi-Fi Direct (Wi-Fi P2P) link — the high-throughput companion to the BLE
/// mesh (NETWORK_PROTOCOL.md §2).
///
/// This is a *second* radio, not a replacement: BLE gives instant, low-power
/// discovery and short-range delivery, while Wi-Fi Direct adds range and
/// bandwidth without any hotspot, router, or pairing step. The native side
/// negotiates the group automatically (each side derives the same group-owner
/// decision from the two device addresses, so exactly one device becomes
/// owner) and carries frames over a length-prefixed TCP socket inside the P2P
/// group.
///
/// All platform work lives in `WifiDirectPlugin.kt`; this class only marshals
/// method/event channel traffic. When the platform side is missing or the
/// radio refuses (no permission, Wi-Fi off, OEM restriction) every method
/// degrades to "unavailable" instead of throwing into the UI.
class WifiDirectTransport {
  static const MethodChannel _method = MethodChannel('itantra/wifidirect');
  static const EventChannel _events = EventChannel('itantra/wifidirect/events');

  final _controller = StreamController<Uint8List>.broadcast();
  StreamSubscription? _eventSub;

  bool _running = false;
  bool _supported = true;
  int _peers = 0;
  String _status = 'off';
  String? _lastError;

  /// Inbound iBFS frames from the P2P group.
  Stream<Uint8List> get incoming => _controller.stream;

  /// Whether the native side accepted `start`.
  bool get isRunning => _running;

  /// Number of P2P sockets currently open.
  int get peerCount => _peers;

  /// Whether this device exposes a Wi-Fi Direct radio at all.
  bool get isSupported => _supported;

  /// Compact state string for the UI (also pushed to the app status banner).
  String get status => _status;

  /// Last platform error, if any — surfaced so failures are diagnosable.
  String? get lastError => _lastError;

  /// Start discovery and group negotiation. Returns `false` when Wi-Fi Direct
  /// is unavailable; callers should simply continue with BLE.
  Future<bool> start() async {
    if (_running) return true;
    if (!Platform.isAndroid) {
      _supported = false;
      _status = 'unsupported';
      return false;
    }

    // Subscribe before starting so no early status event is lost.
    _eventSub ??= _events.receiveBroadcastStream().listen(
          _onEvent,
          onError: (Object e) {
            debugPrint('WifiDirect: event channel error: $e');
            _status = 'error';
          },
        );

    try {
      final ok = await _method.invokeMethod<bool>('start') ?? false;
      if (!ok) {
        _running = false;
        return false;
      }
      _running = true;
      _status = 'searching';
      return true;
    } on MissingPluginException {
      _supported = false;
      _status = 'unsupported';
      return false;
    } on PlatformException catch (e) {
      _lastError = e.message ?? e.code;
      _status = 'unavailable';
      debugPrint('WifiDirect: start failed: $_lastError');
      return false;
    }
  }

  /// Send a frame to every peer in the group. Returns the fanout count.
  Future<int> send(Uint8List frame) async {
    if (!_running) throw StateError('Wi-Fi Direct not started');
    try {
      final sent = await _method.invokeMethod<int>('send', {'data': frame}) ?? 0;
      if (sent == 0) throw StateError('No Wi-Fi Direct peers');
      return sent;
    } on PlatformException catch (e) {
      throw StateError('Wi-Fi Direct send failed: ${e.message ?? e.code}');
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
        debugPrint('WifiDirect: $_lastError');
    }
  }
}
