import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:itantra/net/voice_note.dart';

void main() {
  test('chunk encode/decode round-trips bytes', () {
    final data = Uint8List.fromList(List.generate(200, (i) => i % 251));
    final text = VoiceNoteChunk.encode(
      id: 'A1B2',
      index: 1,
      count: 3,
      data: data,
    );
    final parsed = VoiceNoteChunk.decode(text);
    expect(parsed, isNotNull);
    expect(parsed!.id, 'A1B2');
    expect(parsed.index, 1);
    expect(parsed.count, 3);
    expect(parsed.data, data);
    // One chunk must fit the 512-byte iBFS payload.
    expect(text.length, lessThan(512));
  });

  test('rejects impossible indices and oversized chunks', () {
    expect(
      VoiceNoteChunk.decode('{"v":1,"id":"A","i":3,"n":3,"d":"AA=="}'),
      isNull,
    );
    expect(
      VoiceNoteChunk.decode('{"v":1,"id":"A","i":0,"n":0,"d":"AA=="}'),
      isNull,
    );
    expect(VoiceNoteChunk.decode('not json'), isNull);
  });

  test('assembler rebuilds out-of-order chunks and ignores duplicates', () {
    final assembler = VoiceNoteAssembler();
    final a = List<int>.generate(280, (i) => i % 256);
    final b = List<int>.generate(120, (i) => 255 - i);

    String chunk(int index, int count, List<int> data) => VoiceNoteChunk.encode(
          id: 'FFFF',
          index: index,
          count: count,
          data: data,
        );

    expect(assembler.accept(chunk(1, 2, b)), isNull);
    expect(assembler.accept(chunk(1, 2, b)), isNull);
    final out = assembler.accept(chunk(0, 2, a));
    expect(out, isNotNull);
    expect(out!.length, 400);
    expect(out.sublist(0, 280), a);
    expect(out.sublist(280), b);
    expect(assembler.pendingCount, 0);
  });

  test('assembler discards malformed chunk text', () {
    final assembler = VoiceNoteAssembler();
    expect(assembler.accept('garbage'), isNull);
    expect(assembler.pendingCount, 0);
  });
}
