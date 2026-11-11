import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

/// P2P link abstraction (ARCHITECTURE.md §2 transport stage).
///
/// `send()` writes one raw iBFS frame onto a radio and resolves with the
/// number of peers the frame was handed to; unsolicited inbound frames arrive
/// on `incoming`. Nothing above this layer knows or cares which radio carries
/// the bytes, so BLE, Wi-Fi Direct and loopback are interchangeable.
abstract class Transport {
  /// Writes one frame onto the link; resolves with the peer fanout count.
  Future<int> send(Uint8List frame);

  /// Inbound frames from a connected peer.
  Stream<Uint8List> get incoming;

  /// Whether at least one link is live.
  bool get isConnected;

  /// Tear down the connection.
  Future<void> disconnect();
}

/// Loopback transport for development and demo (no radios needed).
///
/// Simulates a round-trip delay of [minMs]–[maxMs] milliseconds (default
/// 35–90 ms, matching RFCOMM benchmarks) and echoes the frame back, so a
/// single device can exercise the whole pipeline. No encryption, no radio.
///
/// The shipped app does NOT use this — it is a test/demo seam only. Echoing to
/// yourself in production would make a broken link look healthy.
class LoopbackTransport implements Transport {
  final int minMs;
  final int maxMs;
  final _controller = StreamController<Uint8List>.broadcast();
  bool _connected = true;
  final _rng = Random();

  LoopbackTransport({this.minMs = 35, this.maxMs = 90});

  @override
  Stream<Uint8List> get incoming => _controller.stream;

  @override
  bool get isConnected => _connected;

  @override
  Future<int> send(Uint8List frame) async {
    if (!_connected) throw StateError('Transport not connected');

    final delay = minMs + _rng.nextInt(maxMs - minMs + 1);
    await Future.delayed(Duration(milliseconds: delay));

    if (!_controller.isClosed) _controller.add(frame);
    return 1;
  }

  @override
  Future<void> disconnect() async {
    _connected = false;
    await _controller.close();
  }
}
