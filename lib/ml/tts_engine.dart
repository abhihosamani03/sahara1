import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/services.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import 'languages.dart';
import 'tts_model_downloader.dart';

/// Offline text-to-speech back end.
///
/// PRIMARY: sherpa-onnx VITS (MMS) neural TTS, fully on-device after a
/// one-time ~114 MB model download per language.
/// FALLBACK: platform synthesizer (FlutterTts) when the neural model is
/// missing (e.g. Odia) or not yet downloaded.
class TtsEngine {
  final FlutterTts _tts = FlutterTts();
  final AudioPlayer _player = AudioPlayer();
  sherpa.OfflineTts? _neural;
  String? _neuralLangIso;
  String? _currentBcp47;

  /// Playback speed multiplier from the Settings screen (0.5–1.5).
  double _speechRate = 1.0;

  /// The rate currently applied to the platform synthesizer, so a rate change
  /// is pushed to the engine without reconfiguring the language every time.
  double? _appliedRate;

  /// User-selected speech rate. Applies to both the neural and platform paths.
  double get speechRate => _speechRate;
  set speechRate(double v) {
    if (v.isNaN || v <= 0) return;
    _speechRate = v.clamp(0.5, 1.5).toDouble();
    // Force the next _configurePlatform to re-apply the rate.
    _appliedRate = null;
  }

  /// Whether the neural VITS engine is active for the current language.
  bool get isNeuralReady => _neural != null;

  /// Whether the neural VITS engine is loaded for [lang] specifically.
  bool isNeuralReadyFor(Lang lang) =>
      _neural != null && _neuralLangIso == lang.iso639;

  /// Load the neural TTS model for [lang] if it is downloaded.
  /// Returns `true` when the neural engine is ready for [lang].
  Future<bool> initNeural(Lang lang) async {
    if (isNeuralReadyFor(lang)) return true;

    // Free previous instance before loading a new one.
    _freeNeural();

    if (!TtsModelDownloader.hasNeuralModel(lang)) return false;
    if (!await TtsModelDownloader.areModelsAvailable(lang)) return false;

    try {
      final paths = await TtsModelDownloader.ttsPaths(lang);
      final config = sherpa.OfflineTtsConfig(
        model: sherpa.OfflineTtsModelConfig(
          vits: sherpa.OfflineTtsVitsModelConfig(
            model: paths.model,
            tokens: paths.tokens,
            // MMS bundles are char-level tokenizers with no espeak-ng
            // phonemizer data — verified against the official
            // k2-fsa sherpa-onnx vits-mms-* release bundles.
            dataDir: '',
          ),
          numThreads: 2,
          debug: false,
          provider: 'cpu',
        ),
        ruleFsts: '',
        maxNumSenetences: 1,
      );
      _neural = sherpa.OfflineTts(config);
      _neuralLangIso = lang.iso639;
      return true;
    } catch (e) {
      // Corrupted model files can crash init — remove them so the next
      // attempt re-downloads instead of failing forever.
      await TtsModelDownloader.deleteModels(lang);
      _neural = null;
      _neuralLangIso = null;
      return false;
    }
  }

  void _freeNeural() {
    try {
      _neural?.free();
    } catch (_) {}
    _neural = null;
    _neuralLangIso = null;
  }

  /// Configure the platform fallback for the given BCP 47 locale.
  Future<void> _configurePlatform(String bcp47) async {
    final sameLang = _currentBcp47 == bcp47;
    if (sameLang && _appliedRate == _speechRate) return;
    try {
      if (!sameLang) {
        await _tts.setLanguage(bcp47);
        _currentBcp47 = bcp47;
      }
      await _tts.setSpeechRate(_speechRate);
      await _tts.setVolume(1.0);
      await _tts.setPitch(1.0);
      _appliedRate = _speechRate;
    } catch (_) {
      // Platform TTS unavailable (e.g. no TTS engine installed).
    }
  }

  /// Speak [text] aloud in [lang].
  ///
  /// When [emergency] is true, volume is forced to maximum and routed to
  /// the alarm stream (ARCHITECTURE.md §2.3). This requires the
  /// MODIFY_AUDIO_SETTINGS permission.
  ///
  /// Uses the neural VITS engine when its model is loaded for this
  /// language; otherwise falls back to the platform synthesizer.
  Future<void> speak(
    String text, {
    required Lang lang,
    bool emergency = false,
  }) async {
    if (text.isEmpty) return;

    if (emergency) {
      // Request max media volume at the system level.
      try {
        const channel = MethodChannel('itantra/audio_override');
        await channel.invokeMethod('setMaxVolume');
      } on PlatformException {
        // Override not available — continue at current volume.
      } on MissingPluginException {
        // Not running on Android — ignore.
      }
    }

    // ── Neural path (sherpa-onnx VITS) ──
    final neural = _neural;
    if (neural != null && isNeuralReadyFor(lang)) {
      try {
        final audio = neural.generate(
          text: text,
          sid: 0,
          // Emergency speech is nudged faster on top of the user's preference.
          speed: emergency ? _speechRate * 1.1 : _speechRate,
        );
        if (audio.samples.isNotEmpty) {
          await _playPcm(
            audio.samples,
            audio.sampleRate,
            emergency: emergency,
          );
          return;
        }
      } catch (e) {
        // Neural synthesis failed — fall through to platform TTS.
      }
    }

    // ── Platform fallback (FlutterTts) ──
    await _configurePlatform(lang.code);
    try {
      if (emergency) {
        await _tts.setVolume(1.0);
        // Slightly faster for urgency, on top of the user's own rate.
        await _tts.setSpeechRate(_speechRate * 1.15);
      }

      await _tts.speak(text);
      await _tts.awaitSpeakCompletion(true);

      if (emergency) {
        await _tts.setVolume(0.8);
        // Restore the user's rate rather than a hard-coded default, and mark
        // it unapplied so the next call pushes the correct value.
        await _tts.setSpeechRate(_speechRate);
        _appliedRate = null;
      }
    } catch (_) {
      // Platform TTS failed — nothing more we can do.
    }
  }

  /// Encode float PCM samples as a 16-bit WAV file and play it.
  Future<void> _playPcm(
    Float32List samples,
    int sampleRate, {
    bool emergency = false,
  }) async {
    final wav = _encodeWav(samples, sampleRate);
    final dir = await getTemporaryDirectory();
    final file = File(
      '${dir.path}/itantra_tts_${DateTime.now().millisecondsSinceEpoch}.wav',
    );
    await file.writeAsBytes(wav, flush: true);

    try {
      await _player.stop();
      // Emergency: force media volume to maximum before playback.
      if (emergency) {
        try {
          const channel = MethodChannel('itantra/audio_override');
          await channel.invokeMethod('setMaxVolume');
        } on PlatformException {
          // Ignore.
        }
      }
      await _player.play(DeviceFileSource(file.path));
      // Wait for playback to finish so callers can measure TTS duration.
      // A timeout guards against a stalled player freezing the receive
      // path forever.
      await _player.onPlayerComplete.first
          .timeout(const Duration(minutes: 2));
    } on TimeoutException {
      // Playback never signalled completion — move on.
      try {
        await _player.stop();
      } catch (_) {}
    } catch (_) {
      // Playback failed — nothing more we can do.
    } finally {
      try {
        if (await file.exists()) await file.delete();
      } catch (_) {}
    }
  }

  /// Encode mono float samples [-1, 1] into a WAV (PCM 16-bit) byte blob.
  Uint8List _encodeWav(Float32List samples, int sampleRate) {
    final numSamples = samples.length;
    const bytesPerSample = 2;
    final dataSize = numSamples * bytesPerSample;
    final buffer = ByteData(44 + dataSize);

    void writeAscii(int offset, String s) {
      for (var i = 0; i < s.length; i++) {
        buffer.setUint8(offset + i, s.codeUnitAt(i) & 0xFF);
      }
    }

    // RIFF header
    writeAscii(0, 'RIFF');
    buffer.setUint32(4, 36 + dataSize, Endian.little);
    writeAscii(8, 'WAVE');

    // fmt chunk
    writeAscii(12, 'fmt ');
    buffer.setUint32(16, 16, Endian.little); // PCM chunk size
    buffer.setUint16(20, 1, Endian.little); // PCM format
    buffer.setUint16(22, 1, Endian.little); // mono
    buffer.setUint32(24, sampleRate, Endian.little);
    buffer.setUint32(28, sampleRate * bytesPerSample, Endian.little); // byte rate
    buffer.setUint16(32, bytesPerSample, Endian.little); // block align
    buffer.setUint16(34, 16, Endian.little); // bits per sample

    // data chunk
    writeAscii(36, 'data');
    buffer.setUint32(40, dataSize, Endian.little);

    var offset = 44;
    for (var i = 0; i < numSamples; i++) {
      var s = samples[i];
      if (s > 1.0) s = 1.0;
      if (s < -1.0) s = -1.0;
      buffer.setInt16(offset, (s * 32767).round(), Endian.little);
      offset += 2;
    }

    return buffer.buffer.asUint8List();
  }

  /// Whether the engine has been configured.
  bool get isConfigured => _currentBcp47 != null || _neural != null;

  /// Stop any ongoing speech.
  Future<void> stop() async {
    try {
      await _player.stop();
    } catch (_) {}
    try {
      await _tts.stop();
    } catch (_) {}
  }

  /// Dispose resources.
  Future<void> dispose() async {
    await _player.stop();
    await _player.dispose();
    try {
      await _tts.stop();
    } catch (_) {}
    _freeNeural();
    _currentBcp47 = null;
  }
}
