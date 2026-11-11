import 'dart:typed_data';

/// BLE link-layer fragmentation for iBFS frames (NETWORK_PROTOCOL.md §2).
///
/// Why this exists: an iBFS frame is up to 524 bytes (10 header + 512 payload
/// + 2 CRC), while a single BLE ATT write/notify carries only 20–512 bytes
/// depending on the negotiated MTU. A frame therefore has to travel as several
/// chunks.
///
/// Previously the receiver handed each individual ATT chunk to `decodeIbfs()`
/// as if it were a complete frame, which produced the
/// `IbfDecodeError: CRC mismatch: expected 0x3680, computed 0x4e98` errors —
/// the decoder was CRC-ing a truncated buffer with a length-derived CRC
/// offset. Every chunk now carries the envelope below and is reassembled
/// before decoding.
///
/// Chunk envelope (6 bytes, big-endian):
///   byte 0     magic 0xB5 — an iBFS frame always starts with 0x49 'I', so a
///              complete frame can never be mistaken for a chunk
///   byte 1-2   fragment ID (uint16) — one per outbound frame
///   byte 3     chunk index (0-based)
///   byte 4     chunk count
///   byte 5..   chunk data
class FrameFragmenter {
  FrameFragmenter._();

  /// First byte of every chunk envelope.
  static const int magic = 0xB5;

  /// Envelope size in bytes.
  static const int headerLen = 5;

  /// Hard ceiling on chunks per frame (keeps index/count in a single byte).
  static const int maxChunkCount = 255;

  /// Smallest usable ATT payload. 20 bytes is the BLE 4.0 default (MTU 23).
  static const int minAttPayload = 20;
}

/// Splits outbound frames into chunk envelopes.
class FrameSplitter {
  int _nextFragmentId = 0;

  /// Split [frame] into chunks, none larger than [maxChunkBytes] including the
  /// envelope. Returns a single chunk for frames that already fit.
  List<Uint8List> split(Uint8List frame, int maxChunkBytes) {
    final usable = maxChunkBytes <= FrameFragmenter.headerLen
        ? 0
        : maxChunkBytes - FrameFragmenter.headerLen;
    if (usable <= 0) {
      throw ArgumentError('maxChunkBytes=$maxChunkBytes is too small for the '
          '${FrameFragmenter.headerLen}-byte chunk envelope');
    }

    final count = (frame.length + usable - 1) ~/ usable;
    if (count == 0) return const [];
    if (count > FrameFragmenter.maxChunkCount) {
      throw ArgumentError(
        'Frame of ${frame.length} bytes needs $count chunks, max is '
        '${FrameFragmenter.maxChunkCount}',
      );
    }

    _nextFragmentId = (_nextFragmentId + 1) & 0xFFFF;
    final fragmentId = _nextFragmentId;

    final chunks = <Uint8List>[];
    for (var index = 0; index < count; index++) {
      final start = index * usable;
      final end = (start + usable).clamp(0, frame.length);
      final chunk = Uint8List(FrameFragmenter.headerLen + (end - start));
      chunk[0] = FrameFragmenter.magic;
      chunk[1] = (fragmentId >> 8) & 0xFF;
      chunk[2] = fragmentId & 0xFF;
      chunk[3] = index;
      chunk[4] = count;
      chunk.setRange(FrameFragmenter.headerLen, chunk.length, frame, start);
      chunks.add(chunk);
    }
    return chunks;
  }
}

/// Rebuilds frames from inbound chunks.
///
/// State is keyed by `source/fragmentId`, where `source` identifies the peer
/// (and radio) the chunk arrived from, so two peers transmitting concurrently
/// with the same fragment ID cannot be spliced together.
class FrameReassembler {
  /// How long a partially assembled frame is kept before being discarded.
  final int ttlMs;

  /// Maximum number of in-flight assemblies before the oldest is dropped.
  final int maxPending;

  final Map<String, _Assembly> _pending = {};

  FrameReassembler({this.ttlMs = 8000, this.maxPending = 32});

  /// Number of frames currently being reassembled.
  int get pendingCount => _pending.length;

  /// Number of chunks discarded as unusable.
  int get droppedChunks => _droppedChunks;
  int _droppedChunks = 0;

  /// Feed one inbound ATT payload.
  ///
  /// Returns the complete iBFS frame when [chunk] completes an assembly, or
  /// `null` while more chunks are outstanding. A payload that does not start
  /// with the chunk magic is passed straight through, which keeps
  /// single-payload frames (for example the advertisement-carried ones) working.
  Uint8List? accept(String source, Uint8List chunk) {
    if (chunk.isEmpty) return null;

    if (chunk[0] != FrameFragmenter.magic) {
      return chunk;
    }
    if (chunk.length < FrameFragmenter.headerLen) {
      _droppedChunks++;
      return null;
    }

    final fragmentId = (chunk[1] << 8) | chunk[2];
    final index = chunk[3];
    final count = chunk[4];

    if (count == 0 ||
        count > FrameFragmenter.maxChunkCount ||
        index >= count) {
      _droppedChunks++;
      return null;
    }

    _evictExpired();

    final key = '$source/$fragmentId';
    final assembly = _pending.putIfAbsent(key, () => _Assembly(count));
    if (assembly.count != count) {
      // Fragment ID reuse with a mismatched count — start over.
      _pending[key] = _Assembly(count);
      _droppedChunks++;
      return null;
    }

    // A chunk can legitimately arrive more than once: the same frame can come
    // in over BLE *and* Wi-Fi Direct, and relays can echo it back. Re-storing a
    // filled slot must be a no-op — counting duplicates as progress would
    // complete the assembly with holes in it and destroy the frame.
    if (assembly.parts[index] == null) {
      assembly.parts[index] =
          Uint8List.fromList(chunk.sublist(FrameFragmenter.headerLen));
      assembly.received++;
    }

    if (assembly.received < assembly.count) {
      if (_pending.length > maxPending) _evictOldest();
      return null;
    }

    _pending.remove(key);

    var total = 0;
    for (final part in assembly.parts) {
      total += part?.length ?? 0;
    }
    final frame = Uint8List(total);
    var offset = 0;
    for (final part in assembly.parts) {
      if (part == null) {
        _droppedChunks++;
        return null;
      }
      frame.setRange(offset, offset + part.length, part);
      offset += part.length;
    }
    return frame;
  }

  /// Drop all in-flight assemblies (called when a link goes down).
  void reset() => _pending.clear();

  void _evictExpired() {
    if (_pending.isEmpty) return;
    final cutoff = DateTime.now().millisecondsSinceEpoch - ttlMs;
    _pending.removeWhere((_, a) => a.createdAtMs < cutoff);
  }

  void _evictOldest() {
    String? oldestKey;
    int? oldestAt;
    _pending.forEach((key, a) {
      if (oldestAt == null || a.createdAtMs < oldestAt!) {
        oldestAt = a.createdAtMs;
        oldestKey = key;
      }
    });
    if (oldestKey != null) _pending.remove(oldestKey);
  }
}

class _Assembly {
  _Assembly(this.count)
      : parts = List<Uint8List?>.filled(count, null),
        createdAtMs = DateTime.now().millisecondsSinceEpoch;

  final int count;
  final List<Uint8List?> parts;
  final int createdAtMs;
  int received = 0;
}
