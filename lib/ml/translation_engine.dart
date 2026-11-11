import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:google_mlkit_translation/google_mlkit_translation.dart';

import 'languages.dart';

/// Cross-lingual translation bridge (NETWORK_PROTOCOL.md §6).
///
/// This is the step that was missing: a Kannada speaker used to be *spoken* in
/// Kannada on an English-configured receiver, because the translation stage
/// returned `null` and the caller fell back to the original text.
///
/// ## How it works
///
/// ML Kit's on-device translation runs entirely on the phone. Only the
/// **language models** need to come from Google's servers, and only once per
/// language (~30 MB each); after that, translation works with no network at
/// all — which is what makes it usable in a disaster zone.
///
/// ## Why downloads never block reception
///
/// A 30 MB model download on the receive path would stall an incoming SOS for
/// minutes. [ensureModels] therefore **never waits**: it returns `true` when
/// the models are already on disk, and otherwise kicks off the download in the
/// background and returns `false` immediately. The caller speaks the original
/// text this time and gets a translated voice on the next packet. [status]
/// carries progress for the Settings screen.
///
/// ## Coverage
///
/// ML Kit supports 8 of Sahara's 23 languages plus English: Hindi, Bengali,
/// Gujarati, Kannada, Marathi, Tamil, Telugu and Urdu. Languages such as
/// Malayalam, Odia, Punjabi and the north-eastern languages have no ML Kit
/// model; [isSupported] reports `false` for them and the receiver keeps the
/// existing behaviour of showing the original text.
class TranslationEngine {
  /// Live status text for the Settings screen. `null` when idle.
  final ValueNotifier<String?> status = ValueNotifier<String?>(null);

  /// Translator instances, keyed by `source>target`. Creating one per call is
  /// wasteful; ML Kit keeps the model resident inside the instance.
  final Map<String, OnDeviceTranslator> _translators = {};

  /// Pairs whose models are confirmed present on disk.
  final Set<String> _ready = {};

  /// Pairs with a download in flight, so two packets cannot start two
  /// downloads of the same model.
  final Set<String> _downloading = {};

  OnDeviceTranslatorModelManager? _modelManager;

  /// Set once the engine is torn down, so a download that finishes afterwards
  /// cannot write to a disposed notifier.
  bool _disposed = false;

  /// Whether on-device translation can run on this platform.
  ///
  /// ML Kit translation is Android/iOS only; on desktop and in tests there is
  /// no implementation, so callers degrade to the text-only path.
  bool get isAvailable => Platform.isAndroid || Platform.isIOS;

  /// The ML Kit language for [lang], or `null` when ML Kit has no model.
  ///
  /// Matched against ML Kit's own BCP-47 table rather than a hand-written map,
  /// so it stays correct if the plugin adds languages. A plain loop is used
  /// because the plugin exposes the reverse lookup as a static member of an
  /// extension, not of the enum itself.
  static TranslateLanguage? mlKitLanguageFor(Lang lang) {
    for (final candidate in TranslateLanguage.values) {
      if (candidate.bcpCode == lang.iso639) return candidate;
    }
    return null;
  }

  /// Whether ML Kit can translate to or from [lang].
  ///
  /// Pure and platform-independent, so it is safe to assert in unit tests.
  static bool isSupported(Lang lang) => mlKitLanguageFor(lang) != null;

  /// Whether every language in [langs] can be translated.
  static bool supportsAll(Iterable<Lang> langs) => langs.every(isSupported);

  /// Languages ML Kit cannot translate, for a settings hint.
  static List<Lang> unsupportedOf(Iterable<Lang> langs) =>
      langs.where((l) => !isSupported(l)).toList();

  static String _pairKey(Lang a, Lang b) => '${a.iso639}>${b.iso639}';

  /// Publish a status line, ignoring writes after disposal.
  void _setStatus(String? value) {
    if (_disposed) return;
    status.value = value;
  }

  OnDeviceTranslatorModelManager get _manager =>
      _modelManager ??= OnDeviceTranslatorModelManager();

  /// Ensure the translation models for [source] → [target] are on device.
  ///
  /// Returns `true` only when both models are **already** present, so the
  /// caller can translate immediately. Otherwise it starts the download in the
  /// background and returns `false` — it never blocks.
  Future<bool> ensureModels(Lang source, Lang target) async {
    if (!isAvailable) return false;

    final src = mlKitLanguageFor(source);
    final tgt = mlKitLanguageFor(target);
    if (src == null || tgt == null) return false;

    final key = _pairKey(source, target);
    if (_ready.contains(key)) return true;

    try {
      if (await _isDownloaded(src) && await _isDownloaded(tgt)) {
        _ready.add(key);
        _setStatus(null);
        return true;
      }
    } catch (e) {
      debugPrint('[TranslationEngine] model check failed: $e');
      return false;
    }

    unawaited(_download(key, src, tgt, source, target));
    return false;
  }

  /// Start downloading (once) the two models needed for a pair.
  Future<void> _download(
    String key,
    TranslateLanguage src,
    TranslateLanguage tgt,
    Lang source,
    Lang target,
  ) async {
    if (!_downloading.add(key)) return; // Already in flight.

    try {
      _setStatus('Downloading ${source.name} → ${target.name} translation…');
      // isWifiRequired is deliberately false: in a disaster the only link may
      // be cellular, and a 30 MB model is worth the data.
      final a = await _isDownloaded(src)
          ? true
          : await _manager.downloadModel(src.bcpCode, isWifiRequired: false);
      final b = await _isDownloaded(tgt)
          ? true
          : await _manager.downloadModel(tgt.bcpCode, isWifiRequired: false);

      if (a && b) {
        _ready.add(key);
        _setStatus('${source.name} → ${target.name} translation ready');
      } else {
        _setStatus('Translation model download failed — '
            'connect once to download it, then it works offline');
      }
    } catch (e) {
      debugPrint('[TranslationEngine] download failed: $e');
      _setStatus(
          'Translation unavailable — on-device models could not download');
    } finally {
      _downloading.remove(key);
    }
  }

  Future<bool> _isDownloaded(TranslateLanguage lang) async {
    try {
      return await _manager.isModelDownloaded(lang.bcpCode);
    } catch (_) {
      return false;
    }
  }

  /// Translate [text] from [source] to [target], fully on device.
  ///
  /// Returns `null` when translation is unavailable (unsupported language,
  /// models not downloaded yet, non-Android platform, or a failed call), which
  /// is the caller's signal to show and speak the original text. Returns the
  /// text unchanged when both languages are the same.
  Future<String?> translate(String text, Lang source, Lang target) async {
    if (text.trim().isEmpty) return null;
    if (source.iso639 == target.iso639) return text;
    if (!isAvailable) return null;

    final src = mlKitLanguageFor(source);
    final tgt = mlKitLanguageFor(target);
    if (src == null || tgt == null) {
      debugPrint('[TranslationEngine] No ML Kit model for '
          '${source.iso639} → ${target.iso639}; showing original text');
      return null;
    }

    final key = _pairKey(source, target);

    // Models missing: kick off the download and fall back for this message.
    if (!_ready.contains(key)) {
      if (!await ensureModels(source, target)) return null;
    }

    try {
      final translator = _translators.putIfAbsent(
        key,
        () => OnDeviceTranslator(sourceLanguage: src, targetLanguage: tgt),
      );
      final result = await translator.translateText(text);
      if (result.trim().isEmpty) return null;
      return result.trim();
    } catch (e) {
      // A failed translation must never break the receive path or the alarm.
      debugPrint('[TranslationEngine] translate failed: $e');
      // Drop the instance: a translator that threw may be in a bad state.
      final stale = _translators.remove(key);
      unawaited(stale?.close() ?? Future<void>.value());
      return null;
    }
  }

  /// Whether the pair's models are already known to be on device.
  bool isModelReady(Lang source, Lang target) =>
      _ready.contains(_pairKey(source, target));

  /// Whether a download is in flight for the pair.
  bool isDownloading(Lang source, Lang target) =>
      _downloading.contains(_pairKey(source, target));

  /// Delete every downloaded translation model (Settings → clear cache).
  ///
  /// ML Kit exposes no "list my models" call, so this walks the language
  /// registry and deletes each model Sahara could have downloaded.
  /// `deleteModel` is a no-op for a model that is not present.
  Future<void> purgeModels() async {
    if (!isAvailable) return;
    for (final lang in kLanguages) {
      final ml = mlKitLanguageFor(lang);
      if (ml == null) continue;
      try {
        await _manager.deleteModel(ml.bcpCode);
      } catch (e) {
        debugPrint('[TranslationEngine] delete ${ml.bcpCode} failed: $e');
      }
    }
    _ready.clear();
    _setStatus(null);
  }

  /// Free translator resources.
  Future<void> dispose() async {
    _disposed = true;
    for (final t in _translators.values) {
      try {
        await t.close();
      } catch (_) {}
    }
    _translators.clear();
    _modelManager = null;
    status.dispose();
  }
}
