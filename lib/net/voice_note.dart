import 'dart:convert';
import 'dart:typed_data';

/// Voice-note fallback framing.
///
/// Speech recognition fails on heavy accents, noise and uncommon languages —
/// exactly the conditions in an affected village. This carries a short spoken
/// clip as compressed audio (AAC via the recorder, ~16 kbit/s) split across
/// several iBFS frames, so the fallback needs no codec implementation of its
/// own: every chunk is a normal `voiceChunk` packet of 400-450 bytes of JSON.
///
/// Wire form (JSON inside the iBFS text field, kept under 512 bytes):
/// `{"v":1,"id":"A1B2","i":0,"n":7,"d":"<base64>"}`
class VoiceNoteChunk {
  VoiceNoteChunk._();

  /// Raw audio bytes per chunk. 280 bytes → 376 base64 chars; with the header
  /// the whole packet stays inside the 512-byte iBFS payload ceiling.
  static const int maxChunkBytes = 280;

  /// Hard ceiling on chunks per note (~22 s of speech at this bitrate).
  static const int maxChunks = 64;

  /// Hard ceiling on reassembled audio (64 × 280 = 17.9 kB).
  static const int maxNoteBytes = maxChunks * maxChunkBytes;

  static String encode({
    required String id,
    required int index,
    required int count,
    required List<int> data,
  }) =>
      jsonEncode({
        'v': 1,
        'id': id,
        'i': index,
        'n': count,
        'd': base64Encode(data),
      });

  static ParsedVoiceChunk? decode(String text) {
    if (!text.trimLeft().startsWith('{')) return null;
    try {
      final j = jsonDecode(text);
      if (j is! Map<String, dynamic>) return null;
      final id = j['id'];
      final index = j['i'];
      final count = j['n'];
      final data = j['d'];
      if (id is! String || id.isEmpty || id.length > 12) return null;
      if (index is! num || count is! num) return null;
      final i = index.toInt(), n = count.toInt();
      if (n <= 0 || n > maxChunks || i < 0 || i >= n) return null;
      if (data is! String) return null;
      final bytes = base64Decode(data);
      if (bytes.isEmpty || bytes.length > maxChunkBytes) return null;
      return ParsedVoiceChunk(id: id, index: i, count: n, data: bytes);
    } catch (_) {
      return null;
    }
  }
}

class ParsedVoiceChunk {
  const ParsedVoiceChunk({
    required this.id,
    required this.index,
    required this.count,
    required this.data,
  });

  final String id;
  final int index;
  final int count;
  final Uint8List data;
}

/// Reassembles chunks from one sender, keyed by note ID.
class VoiceNoteAssembler {
  VoiceNoteAssembler({
    this.maxPending = 4,
    this.ttl = const Duration(minutes: 6),
  });

  final int maxPending;
  final Duration ttl;
  final Map<String, _Assembly> _pending = {};

  int get pendingCount => _pending.length;

  /// Feed one decoded packet's text. Returns the audio when the note is whole.
  Uint8List? accept(String text) {
    final chunk = VoiceNoteChunk.decode(text);
    if (chunk == null) return null;

    _purgeExpired();

    final existing = _pending[chunk.id];
    if (existing != null && existing.count != chunk.count) {
      // ID reuse with a different length is a new note; start over.
      _pending.remove(chunk.id);
    }
    final assembly = _pending.putIfAbsent(
      chunk.id,
      () => _Assembly(chunk.count),
    );

    if (assembly.parts[chunk.index] == null) {
      assembly.parts[chunk.index] = chunk.data;
      assembly.received++;
    }

    if (assembly.received < assembly.count) {
      while (_pending.length > maxPending) {
        _pending.remove(_pending.keys.first);
      }
      return null;
    }

    _pending.remove(chunk.id);
    final total = assembly.parts.fold<int>(0, (s, p) => s + (p?.length ?? 0));
    if (total == 0 || total > VoiceNoteChunk.maxNoteBytes) return null;
    final out = Uint8List(total);
    var offset = 0;
    for (final part in assembly.parts) {
      if (part == null) return null;
      out.setRange(offset, offset + part.length, part);
      offset += part.length;
    }
    return out;
  }

  void reset() => _pending.clear();

  void _purgeExpired() {
    final cutoff = DateTime.now().subtract(ttl);
    _pending.removeWhere((_, a) => a.createdAt.isBefore(cutoff));
  }
}

class _Assembly {
  _Assembly(this.count)
      : parts = List<Uint8List?>.filled(count, null),
        createdAt = DateTime.now();

  final int count;
  final List<Uint8List?> parts;
  final DateTime createdAt;
  int received = 0;
}
