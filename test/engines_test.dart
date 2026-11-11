import 'package:flutter_test/flutter_test.dart';
import 'package:itantra/ml/languages.dart';
import 'package:itantra/ml/translation_engine.dart';
import 'package:itantra/ml/tts_model_downloader.dart';

/// Languages verified to have an MMS voice on the upstream repo (checked
/// against the actual `model.onnx` + `tokens.txt` URLs). Anything outside this
/// set falls back to the platform synthesizer.
const _mmsLanguages = {
  'hi', 'gu', 'mr', 'kn', 'ta', 'te', 'ml', 'bn', 'en', 'or', 'pa', 'as', 'mai',
};

void main() {
  group('language registry', () {
    test('covers all 22 scheduled languages plus English', () {
      final scheduled = kLanguages.where((l) => l.scheduled).toList();
      expect(scheduled.length, 22,
          reason: 'Eighth Schedule of the Indian Constitution has 22 languages');
      // 22 scheduled + English, which is kept for interop.
      expect(kLanguages.length, 23);
    });

    test('every language has STT and TTS model paths defined', () {
      for (final lang in kLanguages) {
        expect(lang.sttModel, isNotEmpty, reason: '${lang.name} sttModel');
        expect(lang.sttTokens, isNotEmpty, reason: '${lang.name} sttTokens');
        expect(lang.ttsModel, isNotEmpty, reason: '${lang.name} ttsModel');
        expect(lang.ttsTokens, isNotEmpty, reason: '${lang.name} ttsTokens');
      }
    });

    test('each language owns a private voice model path', () {
      // Sharing one path between languages meant downloading a second voice
      // overwrote the first — the previous registry gave every language the
      // same 'models/tts/model.onnx'.
      final paths = kLanguages.map((l) => l.ttsModel).toList();
      expect(paths.toSet().length, paths.length);
      for (final lang in kLanguages) {
        expect(lang.ttsModel, contains('/${lang.iso639}/'));
      }
    });

    test('wire identities are unique', () {
      // The 4-bit nibble only holds 15 direct IDs, so extended languages share
      // the 0xF escape and are told apart by extId. The *pair* must be unique.
      final ids =
          kLanguages.map((l) => '${l.wireId}:${l.extId ?? "-"}').toList();
      expect(ids.toSet().length, ids.length,
          reason: 'Duplicate wire identity breaks iBFS routing');
    });

    test('every language fits the direct range or uses the escape correctly',
        () {
      for (final lang in kLanguages) {
        if (lang.isExtended) {
          expect(lang.wireId, kExtLangEscape);
          expect(lang.extId, isNotNull, reason: '${lang.name} needs an extId');
        } else {
          expect(lang.wireId, lessThan(kExtLangEscape));
          expect(lang.extId, isNull);
        }
      }
      expect(kLanguages.where((l) => l.isExtended).length,
          kLanguages.length - kDirectLangSlots);
    });

    test('the original ten wire IDs are unchanged for backward compatibility',
        () {
      // Guards against a refactor silently breaking interop with an
      // already-deployed build: these exact values were on the wire before the
      // expansion, and the first ten must keep them.
      expect(langByIso639('hi')!.wireId, 0x0);
      expect(langByIso639('gu')!.wireId, 0x1);
      expect(langByIso639('mr')!.wireId, 0x2);
      expect(langByIso639('kn')!.wireId, 0x3);
      expect(langByIso639('ta')!.wireId, 0x4);
      expect(langByIso639('te')!.wireId, 0x5);
      expect(langByIso639('ml')!.wireId, 0x6);
      expect(langByIso639('or')!.wireId, 0x7);
      expect(langByIso639('bn')!.wireId, 0x8);
      expect(langByIso639('en')!.wireId, 0x9);
    });

    test('langByWireId resolves direct and extended languages', () {
      for (final lang in kLanguages) {
        final resolved = langByWireId(lang.wireId, extId: lang.extId);
        expect(resolved?.iso639, lang.iso639,
            reason: '${lang.name} did not round-trip through its wire id');
      }
      expect(langByWireId(kExtLangEscape), isNull,
          reason: 'the escape alone is not a language');
      expect(langByWireId(kExtLangEscape, extId: 99), isNull);
      expect(langByWireId(0xB, extId: 1), langByIso639('ur'));
    });

    test('langToByte / langFromByte round-trip for all languages', () {
      for (final lang in kLanguages) {
        final b = langToByte(lang);
        expect(langFromByte(b)?.iso639, lang.iso639,
            reason: '${lang.name} failed the payload-byte round trip');
      }
      // Direct languages stay in the low nibble range.
      expect(langToByte(kHindi), 0x0);
      // Extended languages move into the 0x10+ block.
      final maithili = langByIso639('mai')!;
      expect(langToByte(maithili), greaterThanOrEqualTo(0x10));
    });
  });

  group('translation language support', () {
    test('ML Kit supports the 8 majors plus English', () {
      expect(TranslationEngine.isSupported(kHindi), isTrue);
      expect(TranslationEngine.isSupported(kEnglish), isTrue);
      expect(TranslationEngine.isSupported(langByIso639('kn')!), isTrue);
      expect(TranslationEngine.isSupported(langByIso639('bn')!), isTrue);
      expect(TranslationEngine.isSupported(langByIso639('ta')!), isTrue);
      expect(TranslationEngine.isSupported(langByIso639('te')!), isTrue);
      expect(TranslationEngine.isSupported(langByIso639('mr')!), isTrue);
      expect(TranslationEngine.isSupported(langByIso639('gu')!), isTrue);
      expect(TranslationEngine.isSupported(langByIso639('ur')!), isTrue);
    });

    test('languages without an ML Kit model report unsupported', () {
      for (final code in ['ml', 'or', 'pa', 'as', 'ne', 'sa', 'sat']) {
        expect(TranslationEngine.isSupported(langByIso639(code)!), isFalse,
            reason: '$code has no ML Kit model');
      }
    });

    test('supportsAll and unsupportedOf agree with isSupported', () {
      expect(TranslationEngine.supportsAll([kHindi, kEnglish]), isTrue);
      expect(
        TranslationEngine.supportsAll([kHindi, langByIso639('ml')!]),
        isFalse,
      );
      final unsupported = TranslationEngine.unsupportedOf(kLanguages);
      expect(unsupported.every((l) => !TranslationEngine.isSupported(l)), isTrue);
      expect(unsupported.length, kLanguages.length - 9,
          reason: 'exactly 9 languages (8 Indic + English) are translatable');
    });

    test('same-language translate returns the text unchanged', () async {
      final engine = TranslationEngine();
      final result = await engine.translate('hello', kEnglish, kEnglish);
      expect(result, 'hello');
      await engine.dispose();
    });

    test('empty text is never sent to the translator', () async {
      final engine = TranslationEngine();
      expect(await engine.translate('   ', kEnglish, kHindi), isNull);
      await engine.dispose();
    });

    test('an unsupported pair degrades to null rather than throwing', () async {
      // Malayalam has no ML Kit model; the receiver must fall back to showing
      // the original text instead of dropping the packet.
      final engine = TranslationEngine();
      final result =
          await engine.translate('ഹലോ', kEnglish, langByIso639('ml')!);
      expect(result, isNull);
      await engine.dispose();
    });

    test('ensureModels reports not-ready instead of blocking', () async {
      // On the test host there is no ML Kit platform channel at all, and even
      // on device this must return false immediately while it downloads rather
      // than stalling the receive path.
      final engine = TranslationEngine();
      final ready = await engine.ensureModels(kHindi, kEnglish);
      expect(ready, isFalse);
      expect(engine.isModelReady(kHindi, kEnglish), isFalse);
      await engine.dispose();
    });
  });

  group('neural TTS model availability', () {
    test('only languages with a verified MMS voice report a neural model', () {
      for (final lang in kLanguages) {
        expect(
          TtsModelDownloader.hasNeuralModel(lang),
          _mmsLanguages.contains(lang.iso639),
          reason: '${lang.name} (${lang.iso639}) TTS model mapping mismatch',
        );
      }
    });

    test('Odia is available under its real MMS code', () {
      final odia = langByIso639('or')!;
      expect(TtsModelDownloader.hasNeuralModel(odia), isTrue);
      expect(odia.ttsModel, contains('/or/'));
    });

    test('languages without an MMS voice fall back to platform TTS', () {
      for (final code in ['sa', 'sd', 'doi', 'ks', 'brx', 'mni', 'sat']) {
        expect(TtsModelDownloader.hasNeuralModel(langByIso639(code)!), isFalse);
      }
    });
  });
}
