import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// One compressed audio burst from the native capture thread.
///
/// [data] holds whole Codec2 frames (8 bytes each at 3200 bps); the plugin
/// batches several of them so the radio sees ~17 packets per second instead of
/// one every 20 ms.
class LiveVoiceFrame {
  const LiveVoiceFrame({
    required this.data,
    required this.frames,
    required this.seq,
    required this.level,
  });

  final Uint8List data;
  final int frames;
  final int seq;

  /// Peak level of the captured frames, 0-100, for a mic meter.
  final int level;

  int get bytes => data.length;
}

/// Real-time Codec2 voice over the mesh.
///
/// The native side owns the microphone and speaker at 8 kHz mono; this class is
/// only the bridge plus honest capability reporting. When the native codec is
/// missing (unsupported ABI, stripped build) [isAvailable] stays false and the
/// app must fall back to speech-to-text or voice notes.
class LiveVoice {
  LiveVoice();

  static const MethodChannel _method = MethodChannel('itantra/codec2');
  static const EventChannel _events = EventChannel('itantra/codec2/events');

  static final LiveVoice instance = LiveVoice();

  final StreamController<LiveVoiceFrame> _frameController =
      StreamController<LiveVoiceFrame>.broadcast();
  final StreamController<int> _levelController =
      StreamController<int>.broadcast();

  StreamSubscription<dynamic>? _sub;

  bool _available = false;
  bool _tx = false;
  bool _rx = false;
  bool _probing = false;
  int _sampleRate = 8000;
  int _samplesPerFrame = 0;
  int _bytesPerFrame = 0;
  String? _lastError;

  bool get isAvailable => _available;
  bool get isTransmitting => _tx;
  bool get isReceiving => _rx;
  int get sampleRate => _sampleRate;
  int get samplesPerFrame => _samplesPerFrame;
  int get bytesPerFrame => _bytesPerFrame;
  String? get lastError => _lastError;

  /// Frames captured by the microphone, ready to be put on the wire.
  Stream<LiveVoiceFrame> get frames => _frameController.stream;

  /// Microphone peak levels (0-100) while transmitting.
  Stream<int> get levels => _levelController.stream;

  void _ensureListening() {
    _sub ??= _events.receiveBroadcastStream().listen(
      _onEvent,
      onError: (Object e) {
        _lastError = e.toString();
        debugPrint('[LiveVoice] event error: $e');
      },
    );
  }

  void _onEvent(dynamic event) {
    if (event is! Map) return;
    final type = event['type'];
    switch (type) {
      case 'tx':
        final data = event['data'];
        if (data is Uint8List && data.isNotEmpty) {
          final level = event['level'] is int ? event['level'] as int : 0;
          _levelController.add(level);
          if (!_frameController.isClosed) {
            _frameController.add(LiveVoiceFrame(
              data: data,
              frames: event['frames'] is int ? event['frames'] as int : 0,
              seq: event['seq'] is int ? event['seq'] as int : 0,
              level: level,
            ));
          }
        }
      case 'started':
        final dir = event['dir'];
        if (dir == 'tx') _tx = true;
        if (dir == 'rx') _rx = true;
      case 'stopped':
        final dir = event['dir'];
        if (dir == 'tx') _tx = false;
        if (dir == 'rx') _rx = false;
      case 'error':
        _lastError = event['message']?.toString();
        debugPrint('[LiveVoice] ${_lastError ?? 'unknown error'}');
    }
  }

  /// Ask the native plugin whether it can encode and decode here.
  Future<bool> probe() async {
    if (_probing) return _available;
    _probing = true;
    try {
      _ensureListening();
      final status = await _method.invokeMapMethod<String, dynamic>('status');
      _available = status?['available'] == true;
      _sampleRate = status?['sampleRate'] is int
          ? status!['sampleRate'] as int
          : _sampleRate;
      _samplesPerFrame = status?['samplesPerFrame'] is int
          ? status!['samplesPerFrame'] as int
          : 0;
      _bytesPerFrame =
          status?['bytesPerFrame'] is int ? status!['bytesPerFrame'] as int : 0;
      return _available;
    } on MissingPluginException {
      _available = false;
      _lastError = 'Live voice needs a full app build';
      return false;
    } catch (e) {
      _available = false;
      _lastError = e.toString();
      debugPrint('[LiveVoice] probe failed: $e');
      return false;
    } finally {
      _probing = false;
    }
  }

  Future<bool> startTx() async {
    if (!_available && !await probe()) return false;
    try {
      _ensureListening();
      final ok = await _method.invokeMethod<bool>('startTx') ?? false;
      _tx = ok;
      return ok;
    } catch (e) {
      _lastError = e.toString();
      debugPrint('[LiveVoice] startTx failed: $e');
      return false;
    }
  }

  Future<void> stopTx() async {
    try {
      await _method.invokeMethod<void>('stopTx');
    } catch (e) {
      debugPrint('[LiveVoice] stopTx failed: $e');
    }
    _tx = false;
  }

  Future<bool> startRx() async {
    if (!_available && !await probe()) return false;
    try {
      _ensureListening();
      final ok = await _method.invokeMethod<bool>('startRx') ?? false;
      _rx = ok;
      return ok;
    } catch (e) {
      _lastError = e.toString();
      debugPrint('[LiveVoice] startRx failed: $e');
      return false;
    }
  }

  Future<void> stopRx() async {
    try {
      await _method.invokeMethod<void>('stopRx');
    } catch (e) {
      debugPrint('[LiveVoice] stopRx failed: $e');
    }
    _rx = false;
  }

  /// Hand received codec frames to the speaker.
  Future<void> push(Uint8List data) async {
    if (data.isEmpty || !_rx) return;
    try {
      await _method.invokeMethod<bool>('push', {'data': data});
    } catch (e) {
      debugPrint('[LiveVoice] push failed: $e');
    }
  }

  Future<void> stop() async {
    try {
      await _method.invokeMethod<void>('stop');
    } catch (e) {
      debugPrint('[LiveVoice] stop failed: $e');
    }
    _tx = false;
    _rx = false;
  }

  Future<void> dispose() async {
    await stop();
    await _sub?.cancel();
    _sub = null;
    try {
      await _method.invokeMethod<void>('release');
    } catch (_) {}
    await _frameController.close();
    await _levelController.close();
  }
}
