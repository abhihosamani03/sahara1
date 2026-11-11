/// Sahara language registry — NETWORK_PROTOCOL.md §3 wire IDs.
///
/// Covers all **22 languages of the Eighth Schedule of the Indian
/// Constitution**, plus English (23 entries total).
///
/// ## Wire encoding
///
/// The iBFS-v1 header packs the language into a **4-bit nibble** (byte 3 low
/// nibble), which can only address 16 values.  There are 23 languages, so the
/// registry uses the layout already reserved by the spec:
///
/// * `0x0 – 0xE` — a language ID written directly into the nibble (15 slots).
/// * `0xF` — **escape**: the nibble carries `0xF` and the real ID travels in a
///   one-byte extension inside the payload (see [PayloadFlags.hasExtLang]).
///
/// The first ten entries deliberately keep the exact wire IDs they had before
/// the expansion, so an existing 10-language build still interoperates
/// byte-for-byte with this one; the escape is only used by the new languages.
///
/// Each language carries its BCP 47 locale string (for STT/TTS engines and for
/// ML Kit translation), its wire ID, and the relative paths to its
/// sherpa-onnx INT8 ONNX models (downloaded at first use via the in-app model
/// manager).
class Lang {
  final String code; // BCP 47 (e.g. 'hi-IN')
  final String name; // Display name
  final int wireId; // 4-bit wire code (0x0–0xF; 0xF == extended escape)
  final int? extId; // Real ID when [wireId] is the escape value
  final String iso639; // Language subtag for engines, HF models, ML Kit
  final String sttModel; // Relative path to INT8 ONNX STT model
  final String sttTokens; // Relative path to STT tokens.txt
  final String ttsModel; // Relative path to VITS ONNX TTS model
  final String ttsTokens; // Relative path to TTS tokens.txt

  /// Whether this is one of the 22 languages of the Eighth Schedule.
  /// (English is supported for interop but is not a scheduled language.)
  final bool scheduled;

  const Lang({
    required this.code,
    required this.name,
    required this.wireId,
    required this.iso639,
    required this.sttModel,
    required this.sttTokens,
    required this.ttsModel,
    required this.ttsTokens,
    this.extId,
    this.scheduled = true,
  });

  /// Whether this language needs the `0xF` escape + payload extension byte.
  bool get isExtended => wireId == kExtLangEscape;

  /// The full wire identity, for logging and tests.
  String get wireLabel => isExtended
      ? '0xF+$extId ($iso639)'
      : '0x${wireId.toRadixString(16)} ($iso639)';

  @override
  String toString() => name;
}

/// 4-bit wire value that escapes to an extended language ID.
///
/// When the header's language nibble holds this value, a one-byte extended
/// language ID follows the source-language field in the payload.
const int kExtLangEscape = 0xF;

/// How many language IDs fit directly in the 4-bit nibble.
const int kDirectLangSlots = kExtLangEscape; // 0x0–0xE inclusive

/// Supported languages — the first ten entries keep their original wire IDs.
///
/// Model paths are relative to the app's documents directory and are
/// downloaded on first use via the in-app model manager.
const List<Lang> kLanguages = [
  // ── Original ten (wire IDs unchanged — backward compatible) ──────────
  Lang(
    code: 'hi-IN', name: 'Hindi', wireId: 0x0, iso639: 'hi',
    sttModel: 'models/stt/hi/model.int8.onnx',
    sttTokens: 'models/stt/hi/tokens.txt',
    ttsModel: 'models/tts/hi/model.onnx',
    ttsTokens: 'models/tts/hi/tokens.txt',
  ),
  Lang(
    code: 'gu-IN', name: 'Gujarati', wireId: 0x1, iso639: 'gu',
    sttModel: 'models/stt/gu/model.int8.onnx',
    sttTokens: 'models/stt/gu/tokens.txt',
    ttsModel: 'models/tts/gu/model.onnx',
    ttsTokens: 'models/tts/gu/tokens.txt',
  ),
  Lang(
    code: 'mr-IN', name: 'Marathi', wireId: 0x2, iso639: 'mr',
    sttModel: 'models/stt/mr/model.int8.onnx',
    sttTokens: 'models/stt/mr/tokens.txt',
    ttsModel: 'models/tts/mr/model.onnx',
    ttsTokens: 'models/tts/mr/tokens.txt',
  ),
  Lang(
    code: 'kn-IN', name: 'Kannada', wireId: 0x3, iso639: 'kn',
    sttModel: 'models/stt/kn/model.int8.onnx',
    sttTokens: 'models/stt/kn/tokens.txt',
    ttsModel: 'models/tts/kn/model.onnx',
    ttsTokens: 'models/tts/kn/tokens.txt',
  ),
  Lang(
    code: 'ta-IN', name: 'Tamil', wireId: 0x4, iso639: 'ta',
    sttModel: 'models/stt/ta/model.int8.onnx',
    sttTokens: 'models/stt/ta/tokens.txt',
    ttsModel: 'models/tts/ta/model.onnx',
    ttsTokens: 'models/tts/ta/tokens.txt',
  ),
  Lang(
    code: 'te-IN', name: 'Telugu', wireId: 0x5, iso639: 'te',
    sttModel: 'models/stt/te/model.int8.onnx',
    sttTokens: 'models/stt/te/tokens.txt',
    ttsModel: 'models/tts/te/model.onnx',
    ttsTokens: 'models/tts/te/tokens.txt',
  ),
  Lang(
    code: 'ml-IN', name: 'Malayalam', wireId: 0x6, iso639: 'ml',
    sttModel: 'models/stt/ml/model.int8.onnx',
    sttTokens: 'models/stt/ml/tokens.txt',
    ttsModel: 'models/tts/ml/model.onnx',
    ttsTokens: 'models/tts/ml/tokens.txt',
  ),
  Lang(
    code: 'or-IN', name: 'Odia', wireId: 0x7, iso639: 'or',
    sttModel: 'models/stt/or/model.int8.onnx',
    sttTokens: 'models/stt/or/tokens.txt',
    ttsModel: 'models/tts/or/model.onnx',
    ttsTokens: 'models/tts/or/tokens.txt',
  ),
  Lang(
    code: 'bn-IN', name: 'Bengali', wireId: 0x8, iso639: 'bn',
    sttModel: 'models/stt/bn/model.int8.onnx',
    sttTokens: 'models/stt/bn/tokens.txt',
    ttsModel: 'models/tts/bn/model.onnx',
    ttsTokens: 'models/tts/bn/tokens.txt',
  ),
  Lang(
    code: 'en-IN', name: 'English', wireId: 0x9, iso639: 'en',
    sttModel: 'models/stt/en/model.int8.onnx',
    sttTokens: 'models/stt/en/tokens.txt',
    ttsModel: 'models/tts/en/model.onnx',
    ttsTokens: 'models/tts/en/tokens.txt',
    scheduled: false,
  ),

  // ── Additional scheduled languages, addressed directly (0xA–0xE) ─────
  Lang(
    code: 'pa-IN', name: 'Punjabi', wireId: 0xA, iso639: 'pa',
    sttModel: 'models/stt/pa/model.int8.onnx',
    sttTokens: 'models/stt/pa/tokens.txt',
    ttsModel: 'models/tts/pa/model.onnx',
    ttsTokens: 'models/tts/pa/tokens.txt',
  ),
  Lang(
    code: 'ur-IN', name: 'Urdu', wireId: 0xB, iso639: 'ur',
    sttModel: 'models/stt/ur/model.int8.onnx',
    sttTokens: 'models/stt/ur/tokens.txt',
    ttsModel: 'models/tts/ur/model.onnx',
    ttsTokens: 'models/tts/ur/tokens.txt',
  ),
  Lang(
    code: 'as-IN', name: 'Assamese', wireId: 0xC, iso639: 'as',
    sttModel: 'models/stt/as/model.int8.onnx',
    sttTokens: 'models/stt/as/tokens.txt',
    ttsModel: 'models/tts/as/model.onnx',
    ttsTokens: 'models/tts/as/tokens.txt',
  ),
  Lang(
    code: 'ne-IN', name: 'Nepali', wireId: 0xD, iso639: 'ne',
    sttModel: 'models/stt/ne/model.int8.onnx',
    sttTokens: 'models/stt/ne/tokens.txt',
    ttsModel: 'models/tts/ne/model.onnx',
    ttsTokens: 'models/tts/ne/tokens.txt',
  ),
  Lang(
    code: 'kok-IN', name: 'Konkani', wireId: 0xE, iso639: 'kok',
    sttModel: 'models/stt/kok/model.int8.onnx',
    sttTokens: 'models/stt/kok/tokens.txt',
    ttsModel: 'models/tts/kok/model.onnx',
    ttsTokens: 'models/tts/kok/tokens.txt',
  ),

  // ── Remaining scheduled languages, addressed via the 0xF escape ──────
  Lang(
    code: 'mai-IN', name: 'Maithili', wireId: kExtLangEscape, extId: 0,
    iso639: 'mai',
    sttModel: 'models/stt/mai/model.int8.onnx',
    sttTokens: 'models/stt/mai/tokens.txt',
    ttsModel: 'models/tts/mai/model.onnx',
    ttsTokens: 'models/tts/mai/tokens.txt',
  ),
  Lang(
    code: 'sa-IN', name: 'Sanskrit', wireId: kExtLangEscape, extId: 1,
    iso639: 'sa',
    sttModel: 'models/stt/sa/model.int8.onnx',
    sttTokens: 'models/stt/sa/tokens.txt',
    ttsModel: 'models/tts/sa/model.onnx',
    ttsTokens: 'models/tts/sa/tokens.txt',
  ),
  Lang(
    code: 'sd-IN', name: 'Sindhi', wireId: kExtLangEscape, extId: 2,
    iso639: 'sd',
    sttModel: 'models/stt/sd/model.int8.onnx',
    sttTokens: 'models/stt/sd/tokens.txt',
    ttsModel: 'models/tts/sd/model.onnx',
    ttsTokens: 'models/tts/sd/tokens.txt',
  ),
  Lang(
    code: 'doi-IN', name: 'Dogri', wireId: kExtLangEscape, extId: 3,
    iso639: 'doi',
    sttModel: 'models/stt/doi/model.int8.onnx',
    sttTokens: 'models/stt/doi/tokens.txt',
    ttsModel: 'models/tts/doi/model.onnx',
    ttsTokens: 'models/tts/doi/tokens.txt',
  ),
  Lang(
    code: 'ks-IN', name: 'Kashmiri', wireId: kExtLangEscape, extId: 4,
    iso639: 'ks',
    sttModel: 'models/stt/ks/model.int8.onnx',
    sttTokens: 'models/stt/ks/tokens.txt',
    ttsModel: 'models/tts/ks/model.onnx',
    ttsTokens: 'models/tts/ks/tokens.txt',
  ),
  Lang(
    code: 'brx-IN', name: 'Bodo', wireId: kExtLangEscape, extId: 5,
    iso639: 'brx',
    sttModel: 'models/stt/brx/model.int8.onnx',
    sttTokens: 'models/stt/brx/tokens.txt',
    ttsModel: 'models/tts/brx/model.onnx',
    ttsTokens: 'models/tts/brx/tokens.txt',
  ),
  Lang(
    code: 'mni-IN', name: 'Manipuri', wireId: kExtLangEscape, extId: 6,
    iso639: 'mni',
    sttModel: 'models/stt/mni/model.int8.onnx',
    sttTokens: 'models/stt/mni/tokens.txt',
    ttsModel: 'models/tts/mni/model.onnx',
    ttsTokens: 'models/tts/mni/tokens.txt',
  ),
  Lang(
    code: 'sat-IN', name: 'Santali', wireId: kExtLangEscape, extId: 7,
    iso639: 'sat',
    sttModel: 'models/stt/sat/model.int8.onnx',
    sttTokens: 'models/stt/sat/tokens.txt',
    ttsModel: 'models/tts/sat/model.onnx',
    ttsTokens: 'models/tts/sat/tokens.txt',
  ),
];

/// Look up a [Lang] by its wire ID.
///
/// [extId] is only consulted when [id] is the [kExtLangEscape] value; it is
/// the extended ID read from the payload's extension byte.
/// Returns `null` for unknown IDs.
Lang? langByWireId(int id, {int? extId}) {
  if (id == kExtLangEscape) {
    if (extId == null) return null;
    for (final l in kLanguages) {
      if (l.isExtended && l.extId == extId) return l;
    }
    return null;
  }
  for (final l in kLanguages) {
    if (!l.isExtended && l.wireId == id) return l;
  }
  return null;
}

/// Look up a [Lang] by ISO 639 code. Returns `null` for unknown codes.
Lang? langByIso639(String code) {
  for (final l in kLanguages) {
    if (l.iso639 == code) return l;
  }
  return null;
}

/// Look up a [Lang] by BCP 47 locale (e.g. 'kn-IN'). Returns `null` if absent.
Lang? langByCode(String code) {
  for (final l in kLanguages) {
    if (l.code == code) return l;
  }
  return null;
}

/// Encode a language into a single payload byte carrying its **full**
/// identity, used by the payload's source-language and extended-language
/// fields.
///
/// * `0x00–0x0F` — the language's own wire ID (directly addressable).
/// * `0x10 + extId` — an escaped language (see [kExtLangEscape]).
///
/// This one-byte form exists because the 4-bit header nibble cannot express 23
/// languages, while the payload fields have room to spare.
int langToByte(Lang lang) =>
    lang.isExtended ? (0x10 + lang.extId!) : lang.wireId;

/// Decode a payload language byte produced by [langToByte].
/// Returns `null` for an unrecognised value.
Lang? langFromByte(int b) =>
    b < 0x10 ? langByWireId(b) : langByWireId(kExtLangEscape, extId: b - 0x10);

/// English fallback language constant.
const Lang kEnglish = Lang(
  code: 'en-IN', name: 'English', wireId: 0x9, iso639: 'en',
  sttModel: 'models/stt/en/model.int8.onnx',
  sttTokens: 'models/stt/en/tokens.txt',
  ttsModel: 'models/tts/en/model.onnx',
  ttsTokens: 'models/tts/en/tokens.txt',
  scheduled: false,
);

/// Hindi fallback language constant.
const Lang kHindi = Lang(
  code: 'hi-IN', name: 'Hindi', wireId: 0x0, iso639: 'hi',
  sttModel: 'models/stt/hi/model.int8.onnx',
  sttTokens: 'models/stt/hi/tokens.txt',
  ttsModel: 'models/tts/hi/model.onnx',
  ttsTokens: 'models/tts/hi/tokens.txt',
);
