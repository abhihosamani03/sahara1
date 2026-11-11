import 'dart:convert';
import 'dart:typed_data';

import 'languages.dart';

/// Sahara Binary Framing Spec (iBFS-v1) — docs/NETWORK_PROTOCOL.md.
///
/// Wire layout (all big-endian):
///   Byte 0-1    Magic 0x49 0x54 ("IT")
///   Byte 2      [Version:4][Type:4]
///   Byte 3      [Priority:4][Lang:4]
///   Byte 4-7    Sequence ID (uint32)
///   Byte 8-9    Payload length N (uint16, <= 512)
///   Byte 10..   Payload: ALWAYS begins with the §4 flags byte
///   ...(10+N)..(11+N)  CRC-16-CCITT over header + payload
///
/// Total overhead: 12 header + 2 CRC = 14 bytes, regardless of payload.
class IbfCodec {
  IbfCodec._();

  // ── Constants ─────────────────────────────────────────────────────
  static const int magic0 = 0x49; // 'I'
  static const int magic1 = 0x54; // 'T'
  static const int headerLen = 10;
  static const int crcLen = 2;
  static const int totalOverhead = headerLen + crcLen; // 12 bytes
  static const int maxPayloadBytes = 512;
}

/// Packet type identifiers (NETWORK_PROTOCOL.md §2, byte 2 low nibble).
///
/// `ack` is a delivery receipt: its header carries the receipt's own sequence
/// ID (so the mesh dedup still works) and its payload text is the decimal
/// sequence ID being confirmed. Receipts are never logged, spoken or alarmed.
enum PacketType {
  pttVoice(0x1),
  silentSos(0x2),
  ack(0x3),
  storeForward(0x4),

  /// Structured triage record: victims, injured, needs, severity, GPS.
  statusReport(0x5),

  /// "I am safe" / "not safe" check-in with a people count.
  checkIn(0x6),

  /// Early-warning alert (severity, radius, expiry, multilingual text).
  alert(0x7),

  /// Responder assignment pushed back to a victim's phone (team + ETA).
  assignment(0x8),

  /// Voice-note fallback: one chunk of compressed audio.
  voiceChunk(0x9),

  /// Relief-camp needs/supplies ledger update.
  reliefUpdate(0xA),

  /// Missing-person record (text fields; the photo stays on the reporter).
  missingPerson(0xB),

  /// Mesh time sample (`{"t":<epoch ms>}`) used to align phone clocks.
  timeSync(0xC),

  /// Responder breadcrumb batch (`{"p":[[lat,lon,ts],...]}`).
  breadcrumb(0xD),

  /// Real-time Codec2 voice: one base64 blob of whole 8-byte codec frames.
  voiceFrame(0xE);

  const PacketType(this.value);
  final int value;
}

/// Priority levels (NETWORK_PROTOCOL.md §2, byte 3 high nibble).
enum Priority {
  routine(0x0),
  high(0x1),
  emergency(0xF);

  const Priority(this.value);
  final int value;
}

/// Extended payload flags byte (NETWORK_PROTOCOL.md §4).
///
/// ```
/// bit 7  HasGPS          lat + lon follow (float32 x2)
/// bit 6  HasSourceLang   sender's language follows (1 byte)
/// bit 5  HasSenderName   name length (1 byte) + UTF-8 name follow
/// bit 4  HasExtLang      extended language ID follows (1 byte)
/// bit 0-3 Reserved
/// ```
///
/// The extension fields are always written in that order, so a receiver can
/// walk the payload with nothing but this byte.
class PayloadFlags {
  final bool hasGps;
  final bool hasSourceLang;

  /// Whether a sender display name is present.
  final bool hasSenderName;

  /// Whether the 4-bit header language is the `0xF` escape, meaning the real
  /// language ID travels in a payload byte.
  final bool hasExtLang;

  const PayloadFlags({
    this.hasGps = false,
    this.hasSourceLang = false,
    this.hasSenderName = false,
    this.hasExtLang = false,
  });

  int toByte() {
    int b = 0;
    if (hasGps) b |= 0x80;
    if (hasSourceLang) b |= 0x40;
    if (hasSenderName) b |= 0x20;
    if (hasExtLang) b |= 0x10;
    return b;
  }

  static PayloadFlags fromByte(int b) {
    return PayloadFlags(
      hasGps: (b & 0x80) != 0,
      hasSourceLang: (b & 0x40) != 0,
      hasSenderName: (b & 0x20) != 0,
      hasExtLang: (b & 0x10) != 0,
    );
  }
}

/// A fully decoded Sahara packet.
class IbfPacket {
  final PacketType type;
  final Priority priority;
  final Lang language;
  final int sequenceId;
  final String text;
  final PayloadFlags flags;
  final double? latitude;
  final double? longitude;
  final Lang? sourceLang;
  final int? measuredTransferMs;

  /// Who sent this message, as set in the sender's Settings screen.
  ///
  /// Limited to [kMaxSenderNameChars] characters so it never crowds out the
  /// actual message on a 512-byte payload.
  final String? senderName;

  const IbfPacket({
    required this.type,
    required this.priority,
    required this.language,
    required this.sequenceId,
    required this.text,
    this.flags = const PayloadFlags(),
    this.latitude,
    this.longitude,
    this.sourceLang,
    this.measuredTransferMs,
    this.senderName,
  });

  /// The message as it should be shown and spoken, with the sender's name
  /// prefixed when one was transmitted.
  String get displayText {
    final name = senderName?.trim();
    if (name == null || name.isEmpty) return text;
    return '[$name] $text';
  }

  /// Whether this packet is an explicit SOS alert (Packet Type 0x2).
  ///
  /// An SOS is deliberately a distinct type, not just a high priority: it must
  /// raise the alarm on every receiving device even when that device's owner
  /// is not looking at the app.
  bool get isSos => type == PacketType.silentSos;

  /// Whether this packet is a structured report (status, check-in, warning or
  /// assignment). Its text is a JSON document, not prose.
  bool get isStructured =>
      type == PacketType.statusReport ||
      type == PacketType.checkIn ||
      type == PacketType.alert ||
      type == PacketType.assignment;

  /// Whether this packet should raise the emergency alarm UI.
  bool get raisesAlarm =>
      isSos || type == PacketType.alert || priority == Priority.emergency;

  /// Short label for the alarm banner and log.
  String get alertLabel => isSos
      ? 'SOS'
      : type == PacketType.alert
          ? 'WARNING'
          : 'EMERGENCY';

  /// Whether this packet is a delivery receipt (Packet Type 0x3).
  bool get isAck => type == PacketType.ack;

  /// The sequence ID this receipt confirms, or `null` when it is not an ACK.
  ///
  /// A receipt cannot reuse the confirmed frame's sequence ID: the mesh dedups
  /// on that field, so the receipt would be dropped as a duplicate of the
  /// frame it is confirming. The confirmed ID therefore travels in the text.
  int? get ackedSequenceId => isAck ? int.tryParse(text.trim()) : null;
}

/// Thrown when a received frame fails validation.
class IbfDecodeError implements Exception {
  final String reason;
  const IbfDecodeError(this.reason);

  @override
  String toString() => 'IbfDecodeError: $reason';
}

/// ── Encoder ──────────────────────────────────────────────────────

/// Longest sender name accepted on the wire.
///
/// The Settings screen enforces the same limit; the encoder clamps again so a
/// name can never overflow the payload or the one-byte length field.
const int kMaxSenderNameChars = 8;

/// Hard byte ceiling for a sender name (8 Indic characters can be 24+ bytes).
const int _maxSenderNameBytes = 64;

/// ── Encoder ──────────────────────────────────────────────────────

/// Encode an [IbfPacket] into its wire-format bytes.
///
/// The flags byte is written *unconditionally* — this is a deliberate fix:
/// sniffing bit 7 is ambiguous because Devanagari/Tamil/etc. UTF-8 lead bytes
/// share those bits, which would silently garble received text.
Uint8List encodeIbfs(IbfPacket packet) {
  // Build the UTF-8 payload.
  final textBytes = utf8.encode(packet.text);
  if (textBytes.length > IbfCodec.maxPayloadBytes) {
    throw ArgumentError(
      'Payload ${textBytes.length} bytes exceeds max ${IbfCodec.maxPayloadBytes}',
    );
  }

  // ── Payload extensions ───────────────────────────────────────────
  // The flags are derived from the bytes actually being written, not taken
  // from `packet.flags`. A caller-supplied flag byte is a footgun: a flag set
  // without its bytes (or bytes written without their flag) shifts every
  // field after it and destroys the frame. Deriving them here makes the
  // encoder and decoder agree by construction.
  final gpsBytes = _encodeGps(packet.latitude, packet.longitude);
  final srcLangByte = packet.sourceLang != null
      ? [langToByte(packet.sourceLang!)]
      : <int>[];
  // The header nibble holds 0xF for languages past the 15 directly
  // addressable IDs; the real ID travels here.
  final extLangByte = packet.language.isExtended
      ? [packet.language.extId! & 0xFF]
      : <int>[];
  final nameBytes = _encodeSenderName(packet.senderName);

  final flags = PayloadFlags(
    hasGps: gpsBytes.isNotEmpty,
    hasSourceLang: srcLangByte.isNotEmpty,
    hasSenderName: nameBytes.isNotEmpty,
    hasExtLang: extLangByte.isNotEmpty,
  );

  // Assemble: flags + gps + srcLang + extLang + name + text
  final payload = [
    flags.toByte(),
    ...gpsBytes,
    ...srcLangByte,
    ...extLangByte,
    ...nameBytes,
    ...textBytes,
  ];

  final payloadLen = payload.length;
  if (payloadLen > IbfCodec.maxPayloadBytes) {
    throw ArgumentError('Assembled payload exceeds max');
  }

  // Header
  final buf = ByteData(IbfCodec.headerLen + payloadLen + IbfCodec.crcLen);

  // Byte 0-1: Magic
  buf.setUint8(0, IbfCodec.magic0);
  buf.setUint8(1, IbfCodec.magic1);

  // Byte 2: [Version:4][Type:4]
  buf.setUint8(2, (0x1 << 4) | (packet.type.value & 0x0F));

  // Byte 3: [Priority:4][Lang:4]
  buf.setUint8(3, ((packet.priority.value & 0x0F) << 4) | (packet.language.wireId & 0x0F));

  // Byte 4-7: Sequence ID (uint32 big-endian)
  buf.setUint32(4, packet.sequenceId, Endian.big);

  // Byte 8-9: Payload length (uint16 big-endian)
  buf.setUint16(8, payloadLen, Endian.big);

  // Byte 10..: Payload
  final headerEnd = IbfCodec.headerLen;
  for (var i = 0; i < payloadLen; i++) {
    buf.setUint8(headerEnd + i, payload[i]);
  }

  // CRC-16-CCITT over header + payload
  final crcOffset = headerEnd + payloadLen;
  final crc = crc16Ccitt(buf.buffer.asUint8List(0, crcOffset));
  buf.setUint16(crcOffset, crc, Endian.big);

  return buf.buffer.asUint8List(buf.offsetInBytes, buf.lengthInBytes);
}

/// ── Decoder ──────────────────────────────────────────────────────

/// Decode raw [bytes] into an [IbfPacket]. Throws [IbfDecodeError] on failure.
IbfPacket decodeIbfs(Uint8List bytes) {
  if (bytes.length < IbfCodec.headerLen + IbfCodec.crcLen) {
    throw IbfDecodeError(
      'Frame too short: ${bytes.length} bytes (min ${IbfCodec.headerLen + IbfCodec.crcLen})',
    );
  }

  // Magic check
  if (bytes[0] != IbfCodec.magic0 || bytes[1] != IbfCodec.magic1) {
    throw IbfDecodeError(
      'Bad magic: 0x${bytes[0].toRadixString(16)}${bytes[1].toRadixString(16)} (expected 0x4954)',
    );
  }

  // CRC-16 check.
  // NOTE: ByteData.sublistView honours bytes.offsetInBytes. Using
  // ByteData.view(bytes.buffer) here read from the start of the *backing*
  // buffer, so any inbound frame that arrived as a view into a larger buffer
  // (which is exactly what BLE chunk reassembly produces) decoded garbage.
  final crcOffset = bytes.length - IbfCodec.crcLen;
  final view = ByteData.sublistView(bytes);
  final expectedCrc = view.getUint16(crcOffset, Endian.big);
  final computedCrc = crc16Ccitt(bytes.sublist(0, crcOffset));
  if (expectedCrc != computedCrc) {
    throw IbfDecodeError(
      'CRC mismatch: expected 0x${expectedCrc.toRadixString(16)}, computed 0x${computedCrc.toRadixString(16)}',
    );
  }

  // Parse header fields
  final b2 = bytes[2];
  final typeVal = b2 & 0x0F;

  final b3 = bytes[3];
  final priorityVal = (b3 >> 4) & 0x0F;
  final langId = b3 & 0x0F;

  final sequenceId = view.getUint32(4, Endian.big);
  final payloadLen = view.getUint16(8, Endian.big);

  // Validate payload length
  final availablePayload = crcOffset - IbfCodec.headerLen;
  if (payloadLen > availablePayload) {
    throw IbfDecodeError(
      'Declared payload $payloadLen exceeds available $availablePayload',
    );
  }

  // Parse packet type
  final type = PacketType.values.firstWhere(
    (t) => t.value == typeVal,
    orElse: () => PacketType.pttVoice,
  );

  // Parse priority
  final priority = Priority.values.firstWhere(
    (p) => p.value == priorityVal,
    orElse: () => Priority.routine,
  );

  // Parse payload: flags byte is ALWAYS first
  if (payloadLen < 1) {
    throw IbfDecodeError('Payload too short (need at least flags byte)');
  }

  final payloadStart = IbfCodec.headerLen;
  final payloadEnd = payloadStart + payloadLen;
  final flags = PayloadFlags.fromByte(bytes[payloadStart]);

  var cursor = payloadStart + 1; // past flags byte

  double? lat;
  double? lon;
  if (flags.hasGps) {
    if (cursor + 8 > payloadEnd) {
      throw IbfDecodeError('GPS flag set but not enough payload bytes');
    }
    lat = view.getFloat32(cursor, Endian.big);
    lon = view.getFloat32(cursor + 4, Endian.big);
    cursor += 8;
  }

  Lang? sourceLang;
  if (flags.hasSourceLang) {
    if (cursor + 1 > payloadEnd) {
      throw IbfDecodeError('SourceLang flag set but not enough payload bytes');
    }
    sourceLang = langFromByte(bytes[cursor]);
    cursor += 1;
  }

  int? extLangId;
  if (flags.hasExtLang) {
    if (cursor + 1 > payloadEnd) {
      throw IbfDecodeError('ExtLang flag set but not enough payload bytes');
    }
    extLangId = bytes[cursor] & 0xFF;
    cursor += 1;
  }

  String? senderName;
  if (flags.hasSenderName) {
    if (cursor + 1 > payloadEnd) {
      throw IbfDecodeError('SenderName flag set but not enough payload bytes');
    }
    final nameLen = bytes[cursor] & 0xFF;
    cursor += 1;
    if (cursor + nameLen > payloadEnd) {
      throw IbfDecodeError(
        'Sender name length $nameLen exceeds remaining payload',
      );
    }
    senderName = utf8
        .decode(bytes.sublist(cursor, cursor + nameLen), allowMalformed: true)
        .trim();
    cursor += nameLen;
  }

  // Resolve the language *after* the payload is walked, because an escaped
  // language (header nibble 0xF) carries its real ID inside the payload.
  //
  // An unrecognised ID means the sender is a newer build using a language
  // this one does not know. Fall back to English rather than rejecting the
  // frame: on a distress channel a readable message beats a dropped one, and
  // the CRC has already proven the bytes are intact.
  final lang = langByWireId(langId, extId: extLangId) ?? kEnglish;

  // Remaining bytes are the UTF-8 text
  final textBytes = bytes.sublist(cursor, payloadEnd);
  final text = utf8.decode(textBytes, allowMalformed: true);

  return IbfPacket(
    type: type,
    priority: priority,
    language: lang,
    sequenceId: sequenceId,
    text: text,
    flags: flags,
    latitude: lat,
    longitude: lon,
    sourceLang: sourceLang,
    senderName: senderName,
  );
}

/// Encode a sender name as `[length][utf-8 bytes]`, or empty when absent.
///
/// The length is a single byte, so the name is clamped to
/// [kMaxSenderNameChars] characters *and* [_maxSenderNameBytes] bytes — eight
/// Devanagari characters can be 24 bytes, and a name must never be able to
/// push the message itself out of the payload.
List<int> _encodeSenderName(String? name) {
  final trimmed = name?.trim() ?? '';
  if (trimmed.isEmpty) return const <int>[];

  var chars = trimmed.runes.toList();
  if (chars.length > kMaxSenderNameChars) {
    chars = chars.sublist(0, kMaxSenderNameChars);
  }

  var encoded = utf8.encode(String.fromCharCodes(chars));
  if (encoded.length > _maxSenderNameBytes) {
    // Drop whole characters until it fits, so the UTF-8 stays well-formed.
    while (chars.isNotEmpty && encoded.length > _maxSenderNameBytes) {
      chars = chars.sublist(0, chars.length - 1);
      encoded = utf8.encode(String.fromCharCodes(chars));
    }
  }
  if (encoded.isEmpty) return const <int>[];
  return <int>[encoded.length, ...encoded];
}

/// ── GPS Helpers ──────────────────────────────────────────────────

Uint8List _encodeGps(double? lat, double? lon) {
  if (lat == null || lon == null) return Uint8List(0);
  final buf = ByteData(8);
  buf.setFloat32(0, lat, Endian.big);
  buf.setFloat32(4, lon, Endian.big);
  return buf.buffer.asUint8List();
}

/// ── CRC-16-CCITT ─────────────────────────────────────────────────

/// CRC-16-CCITT (polynomial 0x1021, init 0xFFFF) — NETWORK_PROTOCOL.md §5.
int crc16Ccitt(List<int> data) {
  var crc = 0xFFFF;
  for (final byte in data) {
    crc ^= byte << 8;
    for (var i = 0; i < 8; i++) {
      if ((crc & 0x8000) != 0) {
        crc = ((crc << 1) ^ 0x1021) & 0xFFFF;
      } else {
        crc = (crc << 1) & 0xFFFF;
      }
    }
  }
  return crc;
}

/// ── Distress Detection ───────────────────────────────────────────

/// Per-language distress keyword lists (ADDITIONAL_FEATURES.md §1).
/// These are run against STT text output — NOT against audio.
const Map<String, List<String>> _distressKeywords = {
  'hi': ['मदद', 'बचाओ', 'घायल', 'फंसे', 'आग', 'emergency', 'help', 'trapped', 'injured', 'fire'],
  'gu': ['મદદ', 'બચાવો', 'ઘાયલ', 'ફસાયા', 'આગ', 'emergency', 'help', 'trapped'],
  'mr': ['मदत', 'वाचवा', 'जखमी', 'अडकले', 'आग', 'emergency', 'help', 'trapped'],
  'kn': ['ಸಹಾಯ', 'ರಕ್ಷಿಸಿ', 'ಗಾಯಗೊಂಡ', 'ಸಿಕ್ಕಿಬಿದ್ದ', 'ಬೆಂಕಿ', 'emergency', 'help', 'trapped'],
  'ta': ['உதவி', 'காப்பாற்று', 'காயமடைந்த', 'சிக்கிய', 'தீ', 'emergency', 'help', 'trapped'],
  'te': ['సహాయం', 'రక్షించండి', 'గాయపడిన', 'చిక్కుకున్న', 'మంట', 'emergency', 'help', 'trapped'],
  'ml': ['സഹായം', 'രക്ഷിക്കൂ', 'മുറിവേറ്റ', 'കുടുങ്ങിയ', 'തീ', 'emergency', 'help', 'trapped'],
  'or': ['ସାହାଯ୍ୟ', 'ବଞ୍ଚାଅ', 'ଆହତ', 'ଫସିଯାଇଛନ୍ତି', 'ଅଗ୍ନି', 'emergency', 'help', 'trapped'],
  'bn': ['সাহায্য', 'বাঁচাও', 'আহত', 'আটকে', 'আগুন', 'emergency', 'help', 'trapped'],
  'pa': ['ਮਦਦ', 'ਬਚਾਓ', 'ਜ਼ਖ਼ਮੀ', 'ਫਸੇ', 'ਅੱਗ'],
  'ur': ['مدد', 'بچا', 'زخمی', 'پھنس', 'آگ'],
  'as': ['সহায়', 'উদ্ধাৰ', 'আঘাত', 'আগুন'],
  'ne': ['मद्दत', 'उद्धार', 'घायल', 'आगो'],
  'kok': ['आदार', 'वाचय', 'घायल'],
  'mai': ['मदति', 'बचाउ', 'आघात'],
  'sa': ['सहायता', 'रक्ष', 'अग्नि'],
  'sd': ['مدد', 'بچايو', 'زخمي'],
  'doi': ['मदद', 'बचाओ', 'ज़ख्मी'],
  'ks': ['مدد', 'بچاؤ', 'زخمی'],
  'en': ['help', 'trapped', 'injured', 'fire', 'emergency', 'sos', 'danger'],
};

/// Returns `true` if the [text] contains distress keywords for the given
/// [langIso639] language code.
///
/// The language's own keyword list is checked **together with** the English
/// one — never instead of it. Indic speech recognition frequently emits Latin
/// transliterations, and an English loanword ("help", "emergency") is common
/// even in an otherwise Hindi or Kannada sentence; missing a real distress
/// call because the speaker code-switched is far worse than a false positive
/// that merely raises a priority flag.
///
/// Languages with no keyword list (e.g. Bodo, Santali) are still covered by
/// the English list, which is the conservative fallback.
bool detectDistress(String text, String langIso639) {
  final lowerText = text.toLowerCase();
  final english = _distressKeywords['en']!;
  final own = _distressKeywords[langIso639];
  final keywords = own == null ? english : [...own, ...english];
  return keywords.any((kw) => lowerText.contains(kw.toLowerCase()));
}
