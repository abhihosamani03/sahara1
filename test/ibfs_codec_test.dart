import 'dart:typed_data' show Uint8List;

import 'package:flutter_test/flutter_test.dart';
import 'package:itantra/ml/ibfs.dart';
import 'package:itantra/ml/languages.dart';

void main() {
  group('iBFS encode/decode round-trip', () {
    test('plain text packet survives a round-trip', () {
      final packet = IbfPacket(
        type: PacketType.pttVoice,
        priority: Priority.routine,
        language: kHindi,
        sequenceId: 42,
        text: 'मदद करो',
      );
      final frame = encodeIbfs(packet);
      final decoded = decodeIbfs(frame);

      expect(decoded.type, PacketType.pttVoice);
      expect(decoded.priority, Priority.routine);
      expect(decoded.language.iso639, 'hi');
      expect(decoded.sequenceId, 42);
      expect(decoded.text, 'मदद करो');
    });

    test('GPS-stamped packet preserves coordinates', () {
      const lat = 30.7333;
      const lon = 79.0667; // Himalayan valley coordinates
      final packet = IbfPacket(
        type: PacketType.pttVoice,
        priority: Priority.emergency,
        language: kHindi,
        sequenceId: 7,
        text: 'मदद करो, मैं घाटी में गिर गया हूँ',
        flags: const PayloadFlags(hasGps: true),
        latitude: lat,
        longitude: lon,
      );
      final decoded = decodeIbfs(encodeIbfs(packet));

      expect(decoded.flags.hasGps, isTrue);
      // Float32 precision — compare with tolerance.
      expect(decoded.latitude!, closeTo(lat, 0.001));
      expect(decoded.longitude!, closeTo(lon, 0.001));
      expect(decoded.priority, Priority.emergency);
    });

    test('multi-byte UTF-8 (Kannada) round-trips correctly', () {
      final packet = IbfPacket(
        type: PacketType.pttVoice,
        priority: Priority.routine,
        language: langByIso639('kn')!,
        sequenceId: 99,
        text: 'ಸಹಾಯ ಮಾಡಿ',
      );
      final decoded = decodeIbfs(encodeIbfs(packet));
      expect(decoded.text, 'ಸಹಾಯ ಮಾಡಿ');
      expect(decoded.language.iso639, 'kn');
    });

    test('frame overhead is 14 bytes + payload', () {
      final packet = IbfPacket(
        type: PacketType.pttVoice,
        priority: Priority.routine,
        language: kEnglish,
        sequenceId: 1,
        text: 'hi',
      );
      final frame = encodeIbfs(packet);
      // 10 header + 1 flags + 2 text + 2 CRC = 15.
      expect(frame.length, 15);
    });

    test('magic bytes are IT', () {
      final frame = encodeIbfs(IbfPacket(
        type: PacketType.pttVoice,
        priority: Priority.routine,
        language: kEnglish,
        sequenceId: 1,
        text: 'x',
      ));
      expect(frame[0], 0x49);
      expect(frame[1], 0x54);
    });
  });

  group('iBFS validation', () {
    test('corrupted payload is rejected (CRC mismatch)', () {
      final frame = encodeIbfs(IbfPacket(
        type: PacketType.pttVoice,
        priority: Priority.routine,
        language: kEnglish,
        sequenceId: 1,
        text: 'hello',
      ));
      // Flip a payload byte.
      frame[12] ^= 0xFF;
      expect(() => decodeIbfs(frame), throwsA(isA<IbfDecodeError>()));
    });

    test('bad magic is rejected', () {
      final frame = encodeIbfs(IbfPacket(
        type: PacketType.pttVoice,
        priority: Priority.routine,
        language: kEnglish,
        sequenceId: 1,
        text: 'x',
      ));
      frame[0] = 0x00;
      expect(() => decodeIbfs(frame), throwsA(isA<IbfDecodeError>()));
    });

    test('truncated frame is rejected', () {
      expect(() => decodeIbfs(Uint8List.fromList([0x49, 0x54, 0x11])),
          throwsA(isA<IbfDecodeError>()));
    });
  });

  group('distress detection', () {
    test('Hindi distress keywords are detected', () {
      expect(detectDistress('मदद करो, मैं घाटी में गिर गया हूँ', 'hi'), isTrue);
      expect(detectDistress('बचाओ!', 'hi'), isTrue);
    });

    test('routine Hindi text is not flagged', () {
      expect(detectDistress('नमस्ते, कैसे हो?', 'hi'), isFalse);
    });

    test('English keywords are detected', () {
      expect(detectDistress('I am injured, send help', 'en'), isTrue);
      expect(detectDistress('hello world', 'en'), isFalse);
    });

    test('Kannada keywords are detected', () {
      expect(detectDistress('ಸಹಾಯ ಮಾಡಿ', 'kn'), isTrue);
    });

    test('unknown language falls back to English keywords', () {
      expect(detectDistress('emergency!', 'xx'), isTrue);
    });

    test('English keywords are caught inside an Indic sentence', () {
      // Code-switching is normal; a Kannada speaker saying "help" must still
      // raise the emergency priority.
      expect(detectDistress('help me ಸಹಾಯ', 'kn'), isTrue);
    });

    test('new scheduled languages have their own keywords', () {
      expect(detectDistress('ਮਦਦ ਕਰੋ', 'pa'), isTrue);
      expect(detectDistress('مدد', 'ur'), isTrue);
      expect(detectDistress('সহায় কৰক', 'as'), isTrue);
      expect(detectDistress('यहाँ कोई आपदा नहीं', 'sa'), isFalse);
    });
  });

  group('sender identity extension', () {
    test('sender name round-trips and is prefixed in displayText', () {
      final packet = IbfPacket(
        type: PacketType.pttVoice,
        priority: Priority.routine,
        language: kHindi,
        sequenceId: 1,
        text: 'मदद करो',
        senderName: 'Vikas',
      );
      final decoded = decodeIbfs(encodeIbfs(packet));

      expect(decoded.senderName, 'Vikas');
      expect(decoded.text, 'मदद करो');
      expect(decoded.displayText, '[Vikas] मदद करो');
      expect(decoded.flags.hasSenderName, isTrue);
    });

    test('no sender name adds no bytes', () {
      final withName = encodeIbfs(IbfPacket(
        type: PacketType.pttVoice,
        priority: Priority.routine,
        language: kEnglish,
        sequenceId: 1,
        text: 'hi',
        senderName: 'Ravi',
      ));
      final without = encodeIbfs(IbfPacket(
        type: PacketType.pttVoice,
        priority: Priority.routine,
        language: kEnglish,
        sequenceId: 1,
        text: 'hi',
      ));
      // 1 length byte + 4 name bytes.
      expect(withName.length, without.length + 5);
      expect(without.length, 15);
      expect(decodeIbfs(without).senderName, isNull);
      expect(decodeIbfs(without).displayText, 'hi');
    });

    test('sender name is clamped to the wire limit', () {
      final decoded = decodeIbfs(encodeIbfs(IbfPacket(
        type: PacketType.pttVoice,
        priority: Priority.routine,
        language: kEnglish,
        sequenceId: 1,
        text: 'x',
        senderName: 'AVeryLongNameIndeed',
      )));
      expect(decoded.senderName!.length, kMaxSenderNameChars);
      expect(decoded.senderName, 'AVeryLon');
    });

    test('a multi-byte sender name survives the round trip', () {
      // 7 Devanagari code points are 21 bytes, so the name's length prefix has
      // to be counted in bytes while the clamp is in characters.
      const name = 'सीताराम';
      expect(name.length, lessThanOrEqualTo(kMaxSenderNameChars));

      final decoded = decodeIbfs(encodeIbfs(IbfPacket(
        type: PacketType.pttVoice,
        priority: Priority.routine,
        language: kHindi,
        sequenceId: 1,
        text: 'नमस्ते',
        senderName: name,
      )));
      expect(decoded.senderName, name);
      expect(decoded.text, 'नमस्ते');
    });

    test('an empty sender name is treated as absent', () {
      final decoded = decodeIbfs(encodeIbfs(IbfPacket(
        type: PacketType.pttVoice,
        priority: Priority.routine,
        language: kEnglish,
        sequenceId: 1,
        text: 'x',
        senderName: '   ',
      )));
      expect(decoded.senderName, isNull);
      expect(decoded.flags.hasSenderName, isFalse);
    });
  });

  group('extended language IDs', () {
    test('every registry language round-trips through the codec', () {
      for (final lang in kLanguages) {
        final decoded = decodeIbfs(encodeIbfs(IbfPacket(
          type: PacketType.pttVoice,
          priority: Priority.routine,
          language: lang,
          sequenceId: 5,
          text: 'ok',
        )));
        expect(decoded.language.iso639, lang.iso639,
            reason: '${lang.name} failed to round-trip');
      }
    });

    test('an escaped language costs exactly one extra byte', () {
      final direct = encodeIbfs(IbfPacket(
        type: PacketType.pttVoice,
        priority: Priority.routine,
        language: kHindi, // wire id 0x0, no escape
        sequenceId: 1,
        text: 'ok',
      ));
      final escaped = encodeIbfs(IbfPacket(
        type: PacketType.pttVoice,
        priority: Priority.routine,
        language: langByIso639('sa')!, // Sanskrit: 0xF escape, extId 1
        sequenceId: 1,
        text: 'ok',
      ));
      expect(escaped.length, direct.length + 1);
      expect(decodeIbfs(escaped).language.iso639, 'sa');
      expect(decodeIbfs(escaped).flags.hasExtLang, isTrue);
    });

    test('an unknown extended language falls back to English, not an error',
        () {
      // Forward compatibility: a newer sender using a language this build does
      // not know must still get a readable message through. Build a valid
      // escaped frame, then point its extension byte at an unmapped id.
      final frame = encodeIbfs(IbfPacket(
        type: PacketType.pttVoice,
        priority: Priority.routine,
        language: langByIso639('mai')!, // escaped, extId 0
        sequenceId: 1,
        text: 'hello',
      ));
      // Layout: 10 header + flags(1) + extLang(1) + text + crc(2).
      expect(frame[11], 0);
      frame[11] = 0xFF; // no language has this extended id
      final decoded = decodeIbfs(_withCorrectedCrc(frame));
      expect(decoded.language.iso639, 'en');
      expect(decoded.text, 'hello');
    });
  });

  group('combined extensions', () {
    test('GPS + source language + name all travel together', () {
      final decoded = decodeIbfs(encodeIbfs(IbfPacket(
        type: PacketType.silentSos,
        priority: Priority.emergency,
        language: langByIso639('mai')!, // extended: 0xF + extId
        sequenceId: 77,
        text: 'SOS — roof collapsed',
        latitude: 25.5941,
        longitude: 85.1376,
        sourceLang: langByIso639('pa')!,
        senderName: 'Asha',
      )));

      expect(decoded.type, PacketType.silentSos);
      expect(decoded.priority, Priority.emergency);
      expect(decoded.language.iso639, 'mai');
      expect(decoded.senderName, 'Asha');
      expect(decoded.sourceLang?.iso639, 'pa');
      expect(decoded.latitude!, closeTo(25.5941, 0.001));
      expect(decoded.longitude!, closeTo(85.1376, 0.001));
      expect(decoded.text, 'SOS — roof collapsed');
      expect(decoded.isSos, isTrue);
      expect(decoded.raisesAlarm, isTrue);
    });

    test('corruption is still caught with every extension present', () {
      final frame = encodeIbfs(IbfPacket(
        type: PacketType.silentSos,
        priority: Priority.emergency,
        language: kHindi,
        sequenceId: 1,
        text: 'SOS',
        latitude: 1.0,
        longitude: 2.0,
        senderName: 'Ravi',
      ));
      frame[12] ^= 0xFF;
      expect(() => decodeIbfs(frame), throwsA(isA<IbfDecodeError>()));
    });

    test('a truncated sender name is rejected rather than silently accepted',
        () {
      final frame = encodeIbfs(IbfPacket(
        type: PacketType.pttVoice,
        priority: Priority.routine,
        language: kEnglish,
        sequenceId: 1,
        text: 'hi',
        senderName: 'Ravi',
      ));
      // Inflate the declared payload length so the name runs past the CRC.
      frame[8] = 0x00;
      frame[9] = 0x40;
      expect(() => decodeIbfs(frame), throwsA(isA<IbfDecodeError>()));
    });
  });
}

/// Recompute the trailing CRC-16 after mutating a frame in a test, so the
/// frame stays structurally valid and only the intended field is "wrong".
Uint8List _withCorrectedCrc(Uint8List frame) {
  final body = frame.sublist(0, frame.length - 2);
  final crc = crc16Ccitt(body);
  final out = <int>[...body, (crc >> 8) & 0xFF, crc & 0xFF];
  return Uint8List.fromList(out);
}
