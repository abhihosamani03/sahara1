import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle, MethodChannel;
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import 'languages.dart';
import 'model_downloader.dart';

typedef SttResultCallback = void Function(String text, bool isFinal);

/// Offline speech-to-text engine using sherpa-onnx with AI4Bharat
/// IndicConformer INT8 ONNX models.
///
/// Architecture (docs/ML_PIPELINE.md §1, §3, §4):
/// - Model: AI4Bharat IndicConformer (NeMo CTC), INT8 quantized
/// - Runtime: sherpa-onnx (C++ core via Dart FFI)
/// - Input: 16kHz mono PCM from device microphone
/// - Output: transcribed text in the selected Indic language
///
/// Model files are downloaded to the app's documents directory on first
/// launch. See scripts/fetch_models.py for the download URLs.
class SttEngine {
  sherpa.OfflineRecognizer? _recognizer;
  sherpa.VoiceActivityDetector? _vad;
  sherpa.VadModelConfig? _vadConfig;
  AudioRecorder? _recorder;
  bool _initialized = false;
  String? _currentLocale;
  StreamSubscription<Uint8List>? _audioSubscription;

  /// Speech text accumulated during the current PTT hold. The VAD only
  /// emits a segment once it has seen enough trailing silence, so a short
  /// utterance spoken right before the button is released would otherwise
  /// be lost. Every finalized VAD segment appends here, and stop() flushes
  /// whatever the VAD still holds so nothing is dropped.
  String _utterance = '';

  /// Generation counter — incremented each start(). If stop() runs before
  /// the async start() completes, the stale start() detects the mismatch
  /// and aborts, preventing a leaked recorder that nobody will stop.
  int _generation = 0;

  /// Trailing silence the VAD must observe before it finalises a sentence.
  ///
  /// Push-to-talk uses a short 0.45 s window so releasing the button sends
  /// quickly; hands-free mode uses 3.0 s so a natural pause does not chop one
  /// sentence into three packets.
  double _minSilence = kPttSilenceSeconds;

  /// Default trailing silence for push-to-talk.
  static const double kPttSilenceSeconds = 0.45;

  /// Trailing silence for hands-free (phone) mode — the competition spec's
  /// "strictly 3.0 seconds of silence" sentence boundary.
  static const double kHandsFreeSilenceSeconds = 3.0;

  /// Continuous capture: each finished sentence is emitted as a *final*
  /// result instead of accumulating into one utterance.
  bool _continuous = false;

  /// While true, inbound audio is discarded and the VAD is reset.
  /// Hands-free mode uses this so the phone's own spoken translation is never
  /// transcribed and re-transmitted — the classic walkie-talkie feedback loop.
  bool _muted = false;

  /// Length of the most recent decoded speech segment, in ms. Reported to the
  /// controller so it can compute the real-time factor (RTF = STT ms / audio ms).
  int _lastUtteranceMs = 0;

  /// Ceiling on the retained session audio (~30 s at 16 kHz). Hands-free mode
  /// can run for hours; without a bound the buffer would grow forever.
  static const int _maxSessionSamples = 16000 * 30;

  /// Duration of the most recent speech segment (ms).
  int get lastUtteranceMs => _lastUtteranceMs;

  /// Wall-clock time spent inside the recognizer, accumulated across the
  /// current utterance. Used to report a real-time factor.
  int _decodeAccumMs = 0;
  int _lastDecodeMs = 0;

  /// Recognizer time for the most recently completed utterance (ms).
  ///
  /// This is deliberately *decode* time, not "time since the button went
  /// down": RTF = decode time / audio duration is the metric that means
  /// something, whereas button-to-text includes however long the speaker held
  /// the button and would always look like RTF ≈ 1.
  int get lastDecodeMs => _lastDecodeMs;

  /// Whether capture is currently muted.
  bool get isMuted => _muted;

  /// Whether capture is in continuous (hands-free) mode.
  bool get isContinuous => _continuous;

  // ── Model download state ──────────────────────────────────────
  bool _downloading = false;
  double _downloadProgress = 0.0;
  String? _downloadingLang;

  /// Whether a model download is currently in progress.
  bool get isDownloading => _downloading;

  /// Current download progress (0.0–1.0).
  double get downloadProgress => _downloadProgress;

  /// Language code currently being downloaded, if any.
  String? get downloadingLang => _downloadingLang;

  /// Check if models are available for [lang] (without initializing).
  Future<bool> hasModels(Lang lang) async {
    await _ensureBundledModel(lang);
    return ModelDownloader.areModelsAvailable(lang);
  }

  /// Ensure models are downloaded for [lang], then initialize the recognizer.
  ///
  /// Downloads models from HuggingFace if not already present.
  /// Returns `true` if models are ready, `false` if download failed.
  Future<bool> prepareModels(
    Lang lang, {
    DownloadProgressCallback? onProgress,
  }) async {
    await _ensureBundledModel(lang);
    if (await ModelDownloader.areModelsAvailable(lang)) {
      return true;
    }

    _downloading = true;
    _downloadProgress = 0.0;
    _downloadingLang = lang.code;

    final success = await ModelDownloader.downloadModels(
      lang,
      onProgress: (progress) {
        _downloadProgress = progress;
        onProgress?.call(progress);
      },
    );

    _downloading = false;
    _downloadProgress = 0.0;
    _downloadingLang = null;

    return success;
  }

  Completer<void>? _bundleExtractCompleter;

  /// Per-language dedup: skip extraction if we already tried this language.
  final Set<String> _extractedLangs = {};

  /// Try to copy bundled asset models into app documents directory.
  /// If no bundled asset exists (model removed from APK to reduce size),
  /// this is a no-op — the caller will download models instead.
  Future<void> _ensureBundledModel(Lang lang) async {
    if (_extractedLangs.contains(lang.code)) return;
    _extractedLangs.add(lang.code);

    if (_bundleExtractCompleter != null) {
      return _bundleExtractCompleter!.future;
    }
    final completer = Completer<void>();
    _bundleExtractCompleter = completer;

    try {
      final appDir = await getApplicationDocumentsDirectory();
      final modelFile = File('${appDir.path}/${lang.sttModel}');
      final tokensFile = File('${appDir.path}/${lang.sttTokens}');

      if (!await modelFile.exists() || await modelFile.length() < 50000000) {
        bool extracted = false;
        if (Platform.isAndroid) {
          try {
            await const MethodChannel('itantra/audio_override').invokeMethod(
              'extractAsset',
              {
                'assetPath': 'assets/${lang.sttModel}',
                'destPath': modelFile.path,
              },
            );
            extracted =
                await modelFile.exists() && await modelFile.length() >= 50000000;
          } catch (e) {
            // Asset not bundled — this is expected when models are not
            // shipped in the APK to reduce size. Download will handle it.
            debugPrint('[SttEngine] Bundled model not available for ${lang.name}: $e');
          }
        }
        if (!extracted) {
          try {
            final byteData = await rootBundle.load('assets/${lang.sttModel}');
            await modelFile.parent.create(recursive: true);
            await modelFile.writeAsBytes(byteData.buffer.asUint8List(
                byteData.offsetInBytes, byteData.lengthInBytes));
            extracted =
                await modelFile.exists() && await modelFile.length() >= 50000000;
          } catch (e) {
            debugPrint('[SttEngine] rootBundle model extract failed: $e');
          }
        }
      }

      if (!await tokensFile.exists() || await tokensFile.length() < 1000) {
        bool extracted = false;
        if (Platform.isAndroid) {
          try {
            await const MethodChannel('itantra/audio_override').invokeMethod(
              'extractAsset',
              {
                'assetPath': 'assets/${lang.sttTokens}',
                'destPath': tokensFile.path,
              },
            );
            extracted =
                await tokensFile.exists() && await tokensFile.length() >= 1000;
          } catch (e) {
            debugPrint('[SttEngine] Bundled tokens not available for ${lang.name}: $e');
          }
        }
        if (!extracted) {
          try {
            final byteData = await rootBundle.load('assets/${lang.sttTokens}');
            await tokensFile.parent.create(recursive: true);
            await tokensFile.writeAsBytes(byteData.buffer.asUint8List(
                byteData.offsetInBytes, byteData.lengthInBytes));
          } catch (e) {
            debugPrint('[SttEngine] rootBundle tokens extract failed: $e');
          }
        }
      }
    } catch (e) {
      debugPrint('[SttEngine] _ensureBundledModel error: $e');
    } finally {
      completer.complete();
      _bundleExtractCompleter = null;
    }
  }

  /// Copy VAD asset from Flutter bundle into app documents directory.
  Future<String?> _ensureVadModel() async {
    try {
      final appDir = await getApplicationDocumentsDirectory();
      final vadPath = '${appDir.path}/silero_vad.onnx';
      if (!await File(vadPath).exists()) {
        final byteData =
            await rootBundle.load('assets/models/vad/silero_vad.onnx');
        await File(vadPath).writeAsBytes(byteData.buffer.asUint8List(
            byteData.offsetInBytes, byteData.lengthInBytes));
      }
      return vadPath;
    } catch (e) {
      debugPrint('[SttEngine] VAD asset copy failed: $e');
      return null;
    }
  }

  /// Initialize the VAD only (no STT model required).
  ///
  /// [minSilenceDuration] is the trailing silence that closes a sentence, and
  /// [force] rebuilds the detector when the mode changes it. The detector is
  /// recreated rather than mutated because sherpa-onnx reads the config at
  /// construction time.
  Future<bool> initVad({
    double minSilenceDuration = kPttSilenceSeconds,
    bool force = false,
  }) async {
    if (_vad != null && !force && _minSilence == minSilenceDuration) return true;
    if (_vad != null && force) {
      try {
        _vad!.free();
      } catch (_) {}
      _vad = null;
    }
    try {
      final vadPath = await _ensureVadModel();
      if (vadPath == null) return false;

      // NOTE (sherpa-onnx VAD constraints):
      // - maxSpeechDuration MUST be well under bufferSizeInSeconds, or the
      //   detector throws / drops segments. 20s max speech inside a 60s
      //   buffer leaves ample headroom.
      // - windowSize 512 is the silero-vad v4 default (matches the bundled
      //   silero_vad.onnx asset).
      _vadConfig = sherpa.VadModelConfig(
        sileroVad: sherpa.SileroVadModelConfig(
          model: vadPath,
          threshold: 0.5,
          minSilenceDuration: minSilenceDuration,
          minSpeechDuration: 0.2,
          windowSize: 512,
          maxSpeechDuration: 20.0,
        ),
        sampleRate: 16000,
        numThreads: 2,
        provider: 'cpu',
        debug: false,
      );

      _vad = sherpa.VoiceActivityDetector(
        config: _vadConfig!,
        bufferSizeInSeconds: 60.0,
      );
      _minSilence = minSilenceDuration;
      return true;
    } catch (e) {
      debugPrint('[SttEngine] VAD init failed: $e');
      _vad = null;
      return false;
    }
  }

  /// Initialize the recognizer for the given language.
  ///
  /// Returns null on success, or an error string describing what failed.
  Future<String?> init(Lang lang) async {
    if (_initialized && _currentLocale == lang.code) return null;

    if (_recognizer != null) {
      _recognizer!.free();
      _recognizer = null;
    }

    await initVad();
    await _ensureBundledModel(lang);

    try {
      final appDir = await getApplicationDocumentsDirectory();
      final modelPath = '${appDir.path}/${lang.sttModel}';
      final tokensPath = '${appDir.path}/${lang.sttTokens}';

      if (!await File(modelPath).exists() ||
          !await File(tokensPath).exists()) {
        _initialized = false;
        return 'model files missing on disk';
      }

      final modelSize = await File(modelPath).length();
      final tokensSize = await File(tokensPath).length();
      if (modelSize < 1000000) {
        try {
          await File(modelPath).delete();
        } catch (_) {}
        _initialized = false;
        return 'model file incomplete ($modelSize bytes) — please retry download';
      }
      if (tokensSize == 0) {
        try {
          await File(tokensPath).delete();
        } catch (_) {}
        _initialized = false;
        return 'tokens file is empty — please retry download';
      }

      _recognizer = sherpa.OfflineRecognizer(
        sherpa.OfflineRecognizerConfig(
          model: sherpa.OfflineModelConfig(
            nemoCtc: sherpa.OfflineNemoEncDecCtcModelConfig(
              model: modelPath,
            ),
            tokens: tokensPath,
            numThreads: 2,
            provider: 'cpu',
            debug: false,
          ),
          decodingMethod: 'greedy_search',
        ),
      );

      _currentLocale = lang.code;
      _initialized = true;
      return null;
    } catch (e, stack) {
      debugPrint('[SttEngine] OfflineRecognizer init failed: $e');
      debugPrint('[SttEngine] Stack: $stack');
      _initialized = false;
      _recognizer = null;
      return e.toString();
    }
  }

  /// Buffer for raw float32 samples across the current PTT session.
  final List<double> _sessionAudioBuffer = [];

  /// Start listening and transcribing.
  ///
  /// Records 16kHz mono PCM from the microphone immediately, detects speech
  /// with Silero VAD, and runs the offline recognizer. Live transcripts stream
  /// to [onResult] while the button is held; [stop] flushes the trailing segment
  /// so short utterances are never lost.
  /// [continuous] selects hands-free behaviour: every VAD-delimited sentence is
  /// emitted as a final result and the recorder keeps running, rather than
  /// accumulating one utterance for the whole hold.
  Future<void> start({
    required String localeId,
    required SttResultCallback onResult,
    bool continuous = false,
  }) async {
    final gen = ++_generation;
    _continuous = continuous;
    _muted = false;

    // Hands-free needs a much longer silence window than push-to-talk.
    final wantedSilence = continuous
        ? kHandsFreeSilenceSeconds
        : kPttSilenceSeconds;
    if (_vad != null && _minSilence != wantedSilence) {
      await initVad(minSilenceDuration: wantedSilence, force: true);
    }

    final lang = kLanguages.firstWhere(
      (l) => l.code == localeId,
      orElse: () => kEnglish,
    );

    // 1. Ensure mic permission and start recording immediately so
    // we never drop audio while models initialize!
    _recorder = AudioRecorder();
    bool hasPerm;
    try {
      hasPerm = await _recorder!.hasPermission();
    } catch (e) {
      debugPrint('[SttEngine] hasPermission threw: $e');
      hasPerm = false;
    }

    if (_generation != gen) {
      _recorder = null;
      return;
    }

    if (!hasPerm) {
      onResult('Microphone permission denied', false);
      _recorder = null;
      return;
    }

    _utterance = '';
    _lastUtteranceMs = 0;
    _decodeAccumMs = 0;
    _lastDecodeMs = 0;
    _sessionAudioBuffer.clear();

    Stream<Uint8List> stream;
    try {
      stream = await _recorder!.startStream(
        const RecordConfig(
          encoder: AudioEncoder.pcm16bits,
          sampleRate: 16000,
          numChannels: 1,
        ),
      );
    } catch (e) {
      debugPrint('[SttEngine] startStream failed: $e');
      onResult('Mic start failed: $e', false);
      _recorder = null;
      return;
    }

    if (_generation != gen) {
      try {
        await _recorder?.stop();
        await _recorder?.dispose();
      } catch (_) {}
      _recorder = null;
      return;
    }

    _audioSubscription = stream.listen(
      (audioData) => _processAudio(audioData, onResult),
      onError: (Object e) {
        debugPrint('[SttEngine] audio stream error: $e');
      },
    );

    // 2. Ensure models are initialized in background
    if (_vad == null || _minSilence != wantedSilence) {
      await initVad(
        minSilenceDuration: wantedSilence,
        force: _vad != null,
      );
    }

    if (!_initialized || _currentLocale != localeId) {
      init(lang).then((_) {
        // The user may have already released the button while the model
        // was loading; stop() owns the buffer in that case. Only decode
        // for the hold that triggered this init.
        if (_generation != gen) return;
        if (_initialized && _recognizer != null && _sessionAudioBuffer.isNotEmpty) {
          final text = _recognize(Float32List.fromList(_sessionAudioBuffer));
          if (text.isNotEmpty && _utterance.isEmpty) {
            _utterance = text;
            onResult(_utterance, false);
          }
        }
      });
    }
  }

  /// Mute or unmute microphone capture.
  ///
  /// Hands-free mode speaks the incoming translation through the same device
  /// that is listening, so without this the neural voice would be recognised
  /// as speech and bounced straight back to the peer. Muting drops the audio
  /// and resets the detector so half a word does not survive the gap.
  void muteCapture(bool muted) {
    if (muted == _muted) return;
    _muted = muted;
    if (muted) {
      _sessionAudioBuffer.clear();
      _noVadBuffer.clear();
      _utterance = '';
      try {
        _vad?.clear();
      } catch (_) {}
    }
  }

  /// Process a chunk of PCM audio through the VAD + recognizer.
  void _processAudio(Uint8List pcmData, SttResultCallback onResult) {
    if (pcmData.isEmpty) return;
    // Our own spoken translation is currently playing — drop the audio.
    if (_muted) return;
    Float32List float32Data;
    try {
      float32Data = _pcm16ToFloat32(pcmData);
    } catch (e) {
      // A malformed PCM chunk must NEVER kill the mic stream: an exception
      // thrown here escapes the stream listener and can tear down the
      // audio subscription, after which every subsequent hold reports
      // "No speech detected". Drop the bad chunk and keep listening.
      debugPrint('[SttEngine] PCM conversion failed, chunk dropped: $e');
      return;
    }
    if (float32Data.isEmpty) return;
    _sessionAudioBuffer.addAll(float32Data);
    // Bound retention so a hands-free session cannot grow without limit.
    if (_sessionAudioBuffer.length > _maxSessionSamples) {
      _sessionAudioBuffer.removeRange(
        0,
        _sessionAudioBuffer.length - _maxSessionSamples,
      );
    }
    final vad = _vad;

    try {
      if (vad != null) {
        vad.acceptWaveform(float32Data);
        while (!vad.isEmpty()) {
          final segment = vad.front();
          if (segment.samples.isNotEmpty) {
            final text = _recognize(segment.samples);
            if (text.isNotEmpty) {
              _lastUtteranceMs =
                  (segment.samples.length * 1000 / 16000).round();
              if (_continuous) {
                // Hands-free: the silence boundary closed this sentence, so
                // send it now and start the next one clean.
                _lastDecodeMs = _decodeAccumMs;
                _decodeAccumMs = 0;
                onResult(text, true);
                _utterance = '';
                _sessionAudioBuffer.clear();
              } else {
                _utterance =
                    _utterance.isEmpty ? text : '$_utterance $text';
                // Live preview while the button is still held.
                onResult(_utterance, false);
              }
            }
          }
          vad.pop();
        }
      } else {
        // No VAD — accumulate audio and decode periodically.
        _noVadBuffer.addAll(float32Data);
        // Decode roughly every 2 seconds for live preview.
        if (_noVadBuffer.length >= 32000) {
          final samples = Float32List.fromList(_noVadBuffer);
          final text = _recognize(samples);
          if (text.isNotEmpty) {
            _lastUtteranceMs = (samples.length * 1000 / 16000).round();
            if (_continuous) {
              _lastDecodeMs = _decodeAccumMs;
              _decodeAccumMs = 0;
              onResult(text, true);
              _sessionAudioBuffer.clear();
            } else {
              _utterance = _utterance.isEmpty ? text : '$_utterance $text';
              onResult(_utterance, false);
            }
          }
          _noVadBuffer.clear();
        }
      }
    } catch (e) {
      debugPrint('[SttEngine] _processAudio error: $e');
    }
  }

  // Buffer for the no-VAD fallback path (decoded every ~2s).
  final List<double> _noVadBuffer = [];

  /// Run the offline recognizer on [samples]; returns text ('' when silent).
  String _recognize(Float32List samples) {
    final recognizer = _recognizer;
    if (recognizer == null || samples.isEmpty) return '';

    final sw = Stopwatch()..start();
    try {
      final stream = recognizer.createStream();
      stream.acceptWaveform(samples: samples, sampleRate: 16000);
      recognizer.decode(stream);
      final result = recognizer.getResult(stream);
      stream.free();
      return result.text.trim();
    } catch (e) {
      debugPrint('[SttEngine] recognize error: $e');
      return '';
    } finally {
      sw.stop();
      _decodeAccumMs += sw.elapsedMilliseconds;
    }
  }

  /// Flush any speech the VAD still holds (utterance tail) and return
  /// the complete transcript for this PTT hold.
  ///
  /// Without this, a sentence spoken with less than `minSilenceDuration`
  /// of trailing silence before the button is released is discarded —
  /// the single most common cause of "the app heard nothing".
  String flushTail() {
    final vad = _vad;
    try {
      if (vad != null) {
        // Force the VAD to emit whatever speech it is currently buffering
        // as a completed segment. Without flush(), ongoing speech that
        // hasn't reached minSilenceDuration stays in the internal buffer
        // and is lost.
        vad.flush();
        while (!vad.isEmpty()) {
          final segment = vad.front();
          if (segment.samples.isNotEmpty) {
            final text = _recognize(segment.samples);
            if (text.isNotEmpty) {
              _utterance = _utterance.isEmpty ? text : '$_utterance $text';
            }
          }
          vad.pop();
        }
      }

      // Also flush the no-VAD accumulator.
      if (_noVadBuffer.isNotEmpty) {
        final text =
            _recognize(Float32List.fromList(_noVadBuffer));
        if (text.isNotEmpty) {
          _utterance = _utterance.isEmpty ? text : '$_utterance $text';
        }
        _noVadBuffer.clear();
      }

      // Reset the VAD buffer so the next hold starts clean; leftover
      // trailing silence must not merge into the next utterance.
      vad?.clear();

      // Fallback 1: If VAD produced nothing, decode the entire session audio buffer directly.
      if (_utterance.trim().isEmpty && _sessionAudioBuffer.isNotEmpty) {
        final text = _recognize(Float32List.fromList(_sessionAudioBuffer));
        if (text.trim().isNotEmpty) {
          _utterance = text.trim();
        }
      }

      // Fallback 2: STT returned nothing. Check whether the user actually
      // spoke before giving up. Phone mics with aggressive AGC often
      // capture speech at very low levels — a strict RMS threshold
      // silently discards REAL speech and surfaces as "No speech detected"
      // while the user IS talking. Declare speech when EITHER the RMS or
      // the peak amplitude clears a relaxed floor.
      if (_utterance.trim().isEmpty && _sessionAudioBuffer.length >= 4800) {
        double sumSquares = 0.0;
        var peak = 0.0;
        for (final s in _sessionAudioBuffer) {
          sumSquares += s * s;
          final a = s.abs();
          if (a > peak) peak = a;
        }
        final rms = math.sqrt(sumSquares / _sessionAudioBuffer.length);
        if (rms > 0.004 || peak > 0.10) {
          debugPrint('[SttEngine] STT empty but audio present '
              '(rms=${rms.toStringAsFixed(4)}, peak=${peak.toStringAsFixed(3)}) '
              '— marking as voice note');
          _utterance = '🎙️ [Voice note]';
        }
      }

      _sessionAudioBuffer.clear();
    } catch (e) {
      debugPrint('[SttEngine] flushTail error: $e');
    }
    _lastDecodeMs = _decodeAccumMs;
    _decodeAccumMs = 0;
    final text = _utterance;
    _utterance = '';
    return text;
  }

  /// Convert int16 PCM bytes to float32 array.
  ///
  /// Uses [ByteData.sublistView] with explicit little-endian reads instead
  /// of `Int16List.view`: the recorder can deliver a chunk whose buffer
  /// offset is not 2-byte aligned, and `Int16List.view` throws RangeError
  /// on misaligned views. ByteData reads have no alignment requirement.
  /// An odd trailing byte is dropped (half a sample) rather than padded.
  Float32List _pcm16ToFloat32(Uint8List pcmBytes) {
    if (pcmBytes.length < 2) return Float32List(0);
    final sampleCount = pcmBytes.length ~/ 2;
    final data = ByteData.sublistView(pcmBytes);
    final float32List = Float32List(sampleCount);
    for (var i = 0; i < sampleCount; i++) {
      float32List[i] = data.getInt16(i * 2, Endian.little) / 32768.0;
    }
    return float32List;
  }

  /// Stop listening and return the final transcript for this hold.
  /// Returns '' when the hold produced no recognizable speech.
  Future<String> stop() async {
    // Invalidate any in-flight start() call so its async gaps abort.
    _generation++;

    await _audioSubscription?.cancel();
    _audioSubscription = null;
    try {
      await _recorder?.stop();
      await _recorder?.dispose();
    } catch (_) {}
    _recorder = null;
    _muted = false;

    // Drain any speech segment still inside the VAD pipeline.
    final text = flushTail();
    _continuous = false;
    return text;
  }

  /// Whether the engine is currently listening.
  bool get isListening => _audioSubscription != null && _recorder != null;

  /// Whether the offline STT models are loaded and ready.
  bool get isReady => _initialized && _recognizer != null;

  /// Whether VAD (at minimum) is ready so PTT can capture audio.
  bool get vadReady => _vad != null;

  /// Current locale.
  String? get currentLocale => _currentLocale;

  /// Dispose resources.
  Future<void> dispose() async {
    _generation++;
    await _audioSubscription?.cancel();
    _audioSubscription = null;
    try {
      await _recorder?.stop();
      await _recorder?.dispose();
    } catch (_) {}
    _recorder = null;
    try {
      _recognizer?.free();
    } catch (_) {}
    _recognizer = null;
    try {
      _vad?.free();
    } catch (_) {}
    _vad = null;
    _initialized = false;
  }
}
