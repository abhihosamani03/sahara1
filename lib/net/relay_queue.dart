import 'dart:typed_data';

import 'mesh_envelope.dart';

/// Store-and-forward for frames this node is *relaying*, not frames it
/// authored.
///
/// `StoreForwardQueue` only ever holds this phone's own messages. A relay that
/// hears a frame while it has no second radio up used to drop it, which breaks
/// the one job of a relay: carrying somebody else's distress call across a gap.
/// Frames are kept here by inner iBFS sequence ID (the mesh dedup key) with a
/// TTL, and retried whenever a peer appears.
class RelayQueue {
  RelayQueue({
    this.maxEntries = 40,
    this.maxAge = const Duration(hours: 2),
    DateTime Function()? clock,
  }) : _now = clock ?? DateTime.now;

  /// Hard cap; a relay must never become an unbounded frame archive.
  final int maxEntries;

  /// A relayed frame older than this is no longer useful in a disaster.
  final Duration maxAge;

  final DateTime Function() _now;
  final Map<int, _RelayEntry> _queue = {};

  int get length => _queue.length;
  bool get isEmpty => _queue.isEmpty;

  /// Sequence IDs currently held, oldest first.
  List<int> get pendingSequenceIds => List.unmodifiable(_queue.keys);

  /// Store [wire] (a complete v2 envelope). Returns the queue length.
  ///
  /// Only well-formed envelopes with a parseable inner sequence ID are kept:
  /// legacy raw frames have no envelope and cannot be re-addressed on flush.
  int enqueue(Uint8List wire) {
    final envelope = decodeMeshEnvelope(wire);
    if (envelope == null) return _queue.length;
    final seq = _sequenceOf(envelope.frame);
    if (seq == null) return _queue.length;
    if (_queue.containsKey(seq)) return _queue.length;

    _queue[seq] = _RelayEntry(wire, _now());
    _purgeExpired();
    while (_queue.length > maxEntries && _queue.isNotEmpty) {
      _queue.remove(_queue.keys.first);
    }
    return _queue.length;
  }

  /// Hand every unexpired frame to [send] once.
  ///
  /// [send] returns the number of peers it reached; an entry is removed only
  /// when that is greater than zero, so a still-dead link keeps the frame.
  Future<int> flush(Future<int> Function(Uint8List wire) send) async {
    var delivered = 0;
    for (final entry in _queue.entries.toList()) {
      if (_now().difference(entry.value.queuedAt) > maxAge) {
        _queue.remove(entry.key);
        continue;
      }
      try {
        final fanout = await send(entry.value.wire);
        if (fanout > 0) {
          _queue.remove(entry.key);
          delivered++;
        }
      } catch (_) {
        // Radio refused again; keep it for the next attempt.
      }
    }
    return delivered;
  }

  void clear() => _queue.clear();

  void _purgeExpired() {
    final cutoff = _now().subtract(maxAge);
    _queue.removeWhere((_, e) => e.queuedAt.isBefore(cutoff));
  }

  static int? _sequenceOf(Uint8List frame) {
    if (frame.length < 8) return null;
    if (frame[0] != 0x49 || frame[1] != 0x54) return null;
    return ByteData.sublistView(frame).getUint32(4, Endian.big);
  }
}

class _RelayEntry {
  _RelayEntry(this.wire, this.queuedAt);
  final Uint8List wire;
  final DateTime queuedAt;
}
