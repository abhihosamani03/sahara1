import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:itantra/ml/ibfs.dart';
import 'package:itantra/ml/languages.dart';
import 'package:itantra/net/fragmentation.dart';

void main() {
  group('FrameSplitter', () {
    test('a frame that fits produces exactly one chunk', () {
      final frame = Uint8List.fromList(List.filled(20, 0x41));
      final chunks = FrameSplitter().split(frame, 64);
      expect(chunks, hasLength(1));
      expect(chunks.first[0], FrameFragmenter.magic);
      expect(chunks.first[3], 0); // index
      expect(chunks.first[4], 1); // count
    });

    test('a frame larger than the ATT payload is split into count chunks', () {
      final frame = Uint8List.fromList(List.generate(524, (i) => i & 0xFF));
      // 40-byte ATT payload => 35 bytes of data per chunk => 15 chunks.
      final chunks = FrameSplitter().split(frame, 40);
      expect(chunks.length, greaterThan(1));
      expect(chunks.every((c) => c.length <= 40), isTrue);
      // Count and payload length add up to the original frame size.
      final dataBytes = chunks.fold<int>(0, (n, c) => n + c.length - 5);
      expect(dataBytes, frame.length);
    });

    test('refuses an unusably small payload budget', () {
      expect(
        () => FrameSplitter().split(Uint8List(10), 5),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('FrameReassembler', () {
    test('reassembles chunks arriving in order', () {
      final frame = Uint8List.fromList(List.generate(300, (i) => i & 0xFF));
      final chunks = FrameSplitter().split(frame, 60);
      final reassembler = FrameReassembler();

      Uint8List? assembled;
      for (final chunk in chunks) {
        assembled = reassembler.accept('peer-a', chunk);
      }
      expect(assembled, isNotNull);
      expect(assembled, equals(frame));
      expect(reassembler.pendingCount, 0);
    });

    test('reassembles chunks arriving out of order', () {
      final frame = Uint8List.fromList(List.generate(400, (i) => (i * 7) & 0xFF));
      final chunks = FrameSplitter().split(frame, 50);
      final reassembler = FrameReassembler();

      Uint8List? assembled;
      for (final chunk in chunks.reversed) {
        assembled = reassembler.accept('peer-a', chunk);
      }
      expect(assembled, equals(frame));
    });

    test('a duplicated chunk does not corrupt the frame', () {
      final frame = Uint8List.fromList(List.generate(250, (i) => i & 0xFF));
      final chunks = FrameSplitter().split(frame, 60);
      final reassembler = FrameReassembler();

      // Re-deliver every chunk twice (the same frame arriving over BLE and
      // Wi-Fi Direct, or echoed by a relay).
      Uint8List? assembled;
      for (final chunk in chunks) {
        final first = reassembler.accept('peer-a', chunk);
        final repeat = reassembler.accept('peer-a', chunk);
        assembled = first ?? repeat ?? assembled;
      }
      expect(assembled, equals(frame));
    });

    test('concurrent senders with the same fragment id do not splice', () {
      final splitter = FrameSplitter();
      final frameA = Uint8List.fromList(List.filled(120, 0xAA));
      final frameB = Uint8List.fromList(List.filled(120, 0xBB));
      final chunksA = splitter.split(frameA, 50);
      final chunksB = splitter.split(frameB, 50);

      // Force the same fragment id by replaying B under A's id.
      final reassembler = FrameReassembler();
      Uint8List? gotA;
      Uint8List? gotB;
      for (var i = 0; i < chunksA.length; i++) {
        gotA = reassembler.accept('peer-a', chunksA[i]) ?? gotA;
        gotB = reassembler.accept('peer-b', chunksB[i]) ?? gotB;
      }
      expect(gotA, equals(frameA));
      expect(gotB, equals(frameB));
    });

    test('a payload without the chunk magic passes straight through', () {
      final raw = Uint8List.fromList(List.filled(16, 0x49));
      final result = FrameReassembler().accept('peer-a', raw);
      expect(result, equals(raw));
    });

    test('an impossible chunk header is discarded', () {
      final reassembler = FrameReassembler();
      final bad = Uint8List.fromList([FrameFragmenter.magic, 0x00, 0x01, 9, 2]);
      expect(reassembler.accept('peer-a', bad), isNull);
      expect(reassembler.droppedChunks, 1);
    });

    test('an incomplete assembly never yields a frame', () {
      final frame = Uint8List.fromList(List.generate(300, (i) => i & 0xFF));
      final chunks = FrameSplitter().split(frame, 60);
      final reassembler = FrameReassembler();

      // Deliver every chunk except the last one.
      for (var i = 0; i < chunks.length - 1; i++) {
        expect(reassembler.accept('peer-a', chunks[i]), isNull);
      }
      expect(reassembler.pendingCount, 1);
    });
  });

  group('fragmentation round-trip through iBFS', () {
    test('a translated voice frame survives split → reassemble → decode', () {
      // This is the regression test for the field failure:
      // "[Corrupt frame dropped] IbfDecodeError: CRC mismatch:
      //  expected 0x3680, computed 0x4e98" — the receiver was decoding raw
      // ATT chunks instead of the reassembled frame.
      final packet = IbfPacket(
        type: PacketType.pttVoice,
        priority: Priority.routine,
        language: kHindi,
        sequenceId: 0x1A2B3C4D,
        text: 'मदद करो, मैं घाटी में फंसा हूँ और पानी बढ़ रहा है',
      );
      final frame = encodeIbfs(packet);
      expect(frame.length, greaterThan(20));

      final chunks = FrameSplitter().split(frame, 23);
      final reassembler = FrameReassembler();
      Uint8List? assembled;
      for (final chunk in chunks) {
        assembled = reassembler.accept('peer-x', chunk) ?? assembled;
      }

      expect(assembled, isNotNull);
      final decoded = decodeIbfs(assembled!);
      expect(decoded.text, packet.text);
      expect(decoded.sequenceId, packet.sequenceId);
      expect(decoded.language.iso639, 'hi');
    });

    test('decoding a frame that is a view into a larger buffer works', () {
      // BLE reassembly hands the decoder a Uint8List view with a non-zero
      // offsetInBytes. The old decoder used ByteData.view(bytes.buffer), which
      // silently read from the start of the backing buffer.
      final packet = IbfPacket(
        type: PacketType.pttVoice,
        priority: Priority.emergency,
        language: kEnglish,
        sequenceId: 7,
        text: 'trapped under debris, need help',
        flags: const PayloadFlags(hasGps: true),
        latitude: 30.7333,
        longitude: 79.0667,
      );
      final frame = encodeIbfs(packet);

      final backing = Uint8List(frame.length + 16);
      backing.setRange(8, 8 + frame.length, frame);
      final view = Uint8List.sublistView(backing, 8, 8 + frame.length);
      expect(view.offsetInBytes, 8);

      final decoded = decodeIbfs(view);
      expect(decoded.sequenceId, 7);
      expect(decoded.text, packet.text);
      expect(decoded.latitude!, closeTo(30.7333, 0.001));
    });
  });
}
