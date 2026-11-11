import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'languages.dart';

/// Callback for download progress updates. [progress] is 0.0 to 1.0.
typedef DownloadProgressCallback = void Function(double progress);

/// Downloads sherpa-onnx compatible VITS (MMS) neural TTS models from
/// HuggingFace for fully offline on-device speech synthesis.
///
/// Source: https://huggingface.co/willwade/mms-tts-multilingual-models-onnx
/// Each model is a VITS `model.onnx` (~114 MB) plus `tokens.txt`.
/// All languages share the same wire format expected by sherpa-onnx's
/// `OfflineTtsVitsModelConfig` (model + tokens, no lexicon/dict).
class TtsModelDownloader {
  TtsModelDownloader._();

  static const String _baseUrl =
      'https://huggingface.co/willwade/mms-tts-multilingual-models-onnx/resolve/main';

  /// MMS 3-letter language code per app language ISO 639 code.
  ///
  /// Every entry here was verified to exist on the upstream repo (both
  /// `model.onnx` and `tokens.txt` return HTTP 200/30x). Languages absent from
  /// this map have no MMS voice published and fall back to the platform
  /// synthesizer, which still speaks them through the phone's own TTS.
  static const Map<String, String> _mmsCodes = {
    'hi': 'hin',
    'gu': 'guj',
    'mr': 'mar',
    'kn': 'kan',
    'ta': 'tam',
    'te': 'tel',
    'ml': 'mal',
    'bn': 'ben',
    'en': 'eng',
    // Verified additions — note Odia's MMS code is 'ory', not 'or'.
    'or': 'ory',
    'pa': 'pan',
    'as': 'asm',
    'mai': 'mai',
  };

  /// Whether a downloadable neural TTS model exists for [lang].
  static bool hasNeuralModel(Lang lang) =>
      _mmsCodes.containsKey(lang.iso639);

  /// Resolve the app-directory paths for [lang]'s TTS model files.
  static Future<({String model, String tokens})> ttsPaths(Lang lang) async {
    final appDir = await getApplicationDocumentsDirectory();
    return (
      model: '${appDir.path}/${lang.ttsModel}',
      tokens: '${appDir.path}/${lang.ttsTokens}',
    );
  }

  /// Check if neural TTS models are already downloaded for [lang].
  static Future<bool> areModelsAvailable(Lang lang) async {
    if (!hasNeuralModel(lang)) return false;
    try {
      final paths = await ttsPaths(lang);
      final modelFile = File(paths.model);
      return await modelFile.exists() && await modelFile.length() > 1000000;
    } catch (_) {
      return false;
    }
  }

  /// Download VITS model + tokens for [lang].
  ///
  /// Reports progress via [onProgress] (0.0–1.0).
  /// Returns `true` on success, `false` on failure.
  static Future<bool> downloadModels(
    Lang lang, {
    DownloadProgressCallback? onProgress,
  }) async {
    final mms = _mmsCodes[lang.iso639];
    if (mms == null) return false; // No neural model for this language.

    final appDir = await getApplicationDocumentsDirectory();
    final modelPath = '${appDir.path}/${lang.ttsModel}';
    final tokensPath = '${appDir.path}/${lang.ttsTokens}';

    try {
      // Download model (98% of progress — tokens are tiny).
      await _downloadFile(
        '$_baseUrl/$mms/model.onnx',
        modelPath,
        onProgress: (p) => onProgress?.call(p * 0.98),
      );

      // Download tokens (remaining 2%).
      await _downloadFile(
        '$_baseUrl/$mms/tokens.txt',
        tokensPath,
        onProgress: (p) => onProgress?.call(0.98 + p * 0.02),
      );

      onProgress?.call(1.0);
      return true;
    } catch (e) {
      // Clean up partial downloads on failure.
      try {
        final modelFile = File(modelPath);
        final tokensFile = File(tokensPath);
        if (await modelFile.exists()) await modelFile.delete();
        if (await tokensFile.exists()) await tokensFile.delete();
      } catch (_) {}
      return false;
    }
  }

  /// Delete downloaded TTS models for [lang] (used on failed init).
  static Future<void> deleteModels(Lang lang) async {
    try {
      final paths = await ttsPaths(lang);
      final modelFile = File(paths.model);
      final tokensFile = File(paths.tokens);
      if (await modelFile.exists()) await modelFile.delete();
      if (await tokensFile.exists()) await tokensFile.delete();
    } catch (_) {}
  }

  /// Download a single file from [url] to [destPath] with progress.
  static Future<void> _downloadFile(
    String url,
    String destPath, {
    DownloadProgressCallback? onProgress,
  }) async {
    final file = File(destPath);
    await file.parent.create(recursive: true);

    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 30);
    try {
      final request = await client.getUrl(Uri.parse(url));
      final response = await request.close().timeout(
            const Duration(seconds: 30),
          );

      if (response.statusCode != 200) {
        throw HttpException('HTTP ${response.statusCode} for $url');
      }

      final totalBytes = response.contentLength;
      var receivedBytes = 0;

      final sink = file.openWrite();
      await for (final chunk in response) {
        sink.add(chunk);
        receivedBytes += chunk.length;
        if (totalBytes > 0) {
          onProgress?.call(receivedBytes / totalBytes);
        }
      }
      await sink.close();
    } finally {
      client.close();
    }
  }
}
