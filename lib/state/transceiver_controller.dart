import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart' as geo;
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/emergency_service.dart';
import '../ml/ibfs.dart';
import '../ml/languages.dart';
import '../ml/stt_engine.dart';
import '../ml/translation_engine.dart';
import '../ml/tts_engine.dart';
import '../ml/tts_model_downloader.dart';
import '../net/live_voice.dart';
import '../net/mesh_clock.dart';
import '../net/mesh_transport.dart';
import '../net/store_forward.dart';
import '../net/transport.dart';
import '../net/voice_note.dart';
import 'alert_feed.dart';
import 'app_settings.dart';
import 'battery_monitor.dart';
import 'breadcrumb_trail.dart';
import 'incident.dart';
import 'missing_registry.dart';
import 'relief_ledger.dart';

/// ── Phase Enum (ARCHITECTURE.md §3) ─────────────────────────────

enum TransceiverPhase {
  idle, // listening for inbound only
  recording, // PTT held, mic capturing
  processing, // STT running on buffered audio
  transmitting, // frame on the wire
}

/// ── Log Entry ───────────────────────────────────────────────────

class LogEntry {
  final int id;
  final DateTime timestamp;
  final bool isSent; // true = transmitted, false = received
  final String text;
  final String langName;
  final Priority priority;
  final int? sttMs;
  final int? transferMs;
  final int? ttsMs;
  final int? e2eMs;
  final double? lat;
  final double? lon;
  final String? error;

  /// Whether this entry is an explicit SOS alert rather than a routine
  /// emergency-priority message.
  final bool sos;

  /// Duration of the speech that produced this message, in ms.
  final int? audioMs;

  /// Recognizer time for this message, in ms (decode only, not the hold).
  final int? decodeMs;

  /// Real-time factor: [decodeMs] / [audioMs]. Below 1.0 means the recognizer
  /// ran faster than real time, which is the number an evaluation wants.
  final double? rtf;

  /// Name the sender transmitted, if any.
  final String? senderName;

  /// Number of delivery receipts (Packet Type 0x3) received for this message.
  ///
  /// Zero means "handed to the radio", not "heard by anybody" — the two used
  /// to be conflated, which made an undelivered SOS look successful.
  final int acks;

  /// Whether the sender is still waiting for a receipt (retries pending).
  final bool awaitingAck;

  /// On-device translation of [text] into this device's receiver language.
  /// Null when the message was already in that language or no model is ready.
  final String? translated;

  const LogEntry({
    required this.id,
    required this.timestamp,
    required this.isSent,
    required this.text,
    required this.langName,
    required this.priority,
    this.sttMs,
    this.transferMs,
    this.ttsMs,
    this.e2eMs,
    this.lat,
    this.lon,
    this.error,
    this.sos = false,
    this.audioMs,
    this.decodeMs,
    this.rtf,
    this.senderName,
    this.acks = 0,
    this.awaitingAck = false,
    this.translated,
  });

  /// Whether this entry carries a position worth plotting.
  bool get hasPosition => lat != null && lon != null;

  /// Short delivery state for a sent entry, or null when it does not apply.
  ///
  /// `delivered` requires a receipt from a peer. A frame that was only handed
  /// to the radio says `sent` and a frame still being retried says `sending`.
  String? get deliveryLabel {
    if (!isSent) return null;
    if (acks > 0) return acks == 1 ? 'delivered' : 'delivered ×$acks';
    if (awaitingAck) return 'sending…';
    return 'sent';
  }

  LogEntry copyWith({
    int? acks,
    bool? awaitingAck,
    String? error,
    bool clearError = false,
    String? translated,
    DateTime? timestamp,
  }) =>
      LogEntry(
        id: id,
        timestamp: timestamp ?? this.timestamp,
        isSent: isSent,
        text: text,
        langName: langName,
        priority: priority,
        sttMs: sttMs,
        transferMs: transferMs,
        ttsMs: ttsMs,
        e2eMs: e2eMs,
        lat: lat,
        lon: lon,
        error: clearError ? null : (error ?? this.error),
        sos: sos,
        audioMs: audioMs,
        decodeMs: decodeMs,
        rtf: rtf,
        senderName: senderName,
        acks: acks ?? this.acks,
        awaitingAck: awaitingAck ?? this.awaitingAck,
        translated: translated ?? this.translated,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'ts': timestamp.millisecondsSinceEpoch,
        'sent': isSent,
        'text': text,
        'lang': langName,
        'priority': priority.value,
        'sttMs': sttMs,
        'txMs': transferMs,
        'ttsMs': ttsMs,
        'e2eMs': e2eMs,
        'lat': lat,
        'lon': lon,
        'error': error,
        'sos': sos,
        'audioMs': audioMs,
        'decodeMs': decodeMs,
        'rtf': rtf,
        'name': senderName,
        'acks': acks,
        'awaiting': awaitingAck,
        'translated': translated,
      };

  factory LogEntry.fromJson(Map<String, dynamic> j) => LogEntry(
        id: j['id'] as int,
        timestamp: DateTime.fromMillisecondsSinceEpoch(j['ts'] as int),
        isSent: j['sent'] as bool,
        text: j['text'] as String,
        langName: j['lang'] as String,
        priority: Priority.values.firstWhere(
          (p) => p.value == j['priority'],
          orElse: () => Priority.routine,
        ),
        sttMs: j['sttMs'] as int?,
        transferMs: j['txMs'] as int?,
        ttsMs: j['ttsMs'] as int?,
        e2eMs: j['e2eMs'] as int?,
        lat: (j['lat'] as num?)?.toDouble(),
        lon: (j['lon'] as num?)?.toDouble(),
        error: j['error'] as String?,
        sos: j['sos'] as bool? ?? false,
        audioMs: j['audioMs'] as int?,
        decodeMs: j['decodeMs'] as int?,
        rtf: (j['rtf'] as num?)?.toDouble(),
        senderName: j['name'] as String?,
        acks: (j['acks'] as int?) ?? 0,
        awaitingAck: (j['awaiting'] as bool?) ?? false,
        translated: j['translated'] as String?,
      );
}

/// ── Transceiver Controller ──────────────────────────────────────

/// Core PTT state machine (ARCHITECTURE.md §3).
///
/// All mutation flows through this class. Widgets are projections of
/// its [ValueNotifier] fields.
class TransceiverController extends ChangeNotifier {
  final SttEngine stt;
  final TtsEngine tts;
  final Transport transport;
  final TranslationEngine translator;

  /// Shared, persisted user preferences.
  final AppSettings settings;

  /// Battery/thermal monitor, when the app provides one. Null in unit tests
  /// that do not care about power state.
  final BatteryMonitor? battery;

  /// Mesh-wide clock estimate, fed by `timeSync` packets.
  final MeshClock clock;

  /// Local and heard GPS breadcrumb trails.
  final BreadcrumbTrail breadcrumbs;

  late final StoreForwardQueue storeForward;

  TransceiverController({
    required this.stt,
    required this.tts,
    required this.transport,
    required this.settings,
    this.battery,
    MeshClock? clock,
    BreadcrumbTrail? breadcrumbs,
    TranslationEngine? translator,
  })  : clock = clock ?? MeshClock(),
        breadcrumbs = breadcrumbs ?? BreadcrumbTrail(),
        translator = translator ?? TranslationEngine() {
    storeForward = StoreForwardQueue(transport);
    tts.speechRate = settings.speechRate;
    _listenInbound();
    _listenSilentSos();
    // Real-time voice: frames captured by the native codec go straight onto
    // the mesh, and frames received from the mesh go straight to the speaker.
    _liveVoiceSub = _liveVoice.frames.listen(_onCapturedVoiceFrame);

    // Every board change must repaint the screens that watch the controller.
    _incidents.addListener(notifyListeners);
    unawaited(_incidents.load());
    _relief.addListener(notifyListeners);
    unawaited(_relief.load());
    _missing.addListener(notifyListeners);
    unawaited(_missing.load());

    // React to preference changes (speech rate, mode, role, hardware toggle).
    settings.addListener(_onSettingsChanged);

    // Mirror radio-state changes into the UI. The mesh emits only when the
    // link signature actually changes, so this does not cause rebuild churn.
    final t = transport;
    if (t is MeshTransport) {
      _linkSubscription = t.linkChanged.listen((_) {
        notifyListeners();
        if (t.stats.hasPeers) _maybeSyncClock();
      });
    }

    // Periodic mesh clock sample. The first peer to appear also triggers one,
    // so a phone that joins late converges without waiting five minutes.
    _timeSyncTimer = Timer.periodic(
      const Duration(minutes: 5),
      (_) => unawaited(_sendTimeSync()),
    );
    _refreshBreadcrumbPolicy();

    // Delay radio start so the runtime permission dialog can be answered
    // first. HomeScreen._requestPermissions() also calls enableMesh() as soon
    // as permissions are granted; this timer is the fallback path.
    Future.delayed(const Duration(seconds: 3), () {
      if (!_meshActive) _startMeshOnInit();
    });
  }

  StreamSubscription<void>? _linkSubscription;
  StreamSubscription<void>? _silentSosSubscription;
  Timer? _timeSyncTimer;
  Timer? _breadcrumbTimer;
  DateTime? _lastClockSync;
  bool _relayModeApplied = false;

  /// Auto-start the radios in the background.
  Future<void> _startMeshOnInit() async {
    final t = transport;
    if (t is! MeshTransport) return;
    if (settings.relayMode != t.relayMode) {
      await t.setRelayMode(settings.relayMode);
    }
    _relayModeApplied = settings.relayMode;
    final ok = await t.start();
    _meshActive = ok;
    if (!ok) _statusMessage = t.stats.failureHint ?? _statusMessage;
    notifyListeners();

    // Standby keeps this isolate alive with no Activity attached, which is what
    // lets an SOS arrive when the app looks closed. Started regardless of the
    // radio result: it also keeps the radio retry loop running.
    await enableStandby();

    // Hands-free listens continuously, so it only makes sense once the radios
    // (and therefore the mic pipeline) are up.
    if (settings.isHandsFree && settings.canTransmit) {
      await startHandsFree();
    }
  }

  /// Apply preference changes that the controller owns.
  void _onSettingsChanged() {
    tts.speechRate = settings.speechRate;
    unawaited(EmergencyService.setSilentSosEnabled(settings.silentSosEnabled));

    if (_relayModeApplied != settings.relayMode) {
      _relayModeApplied = settings.relayMode;
      unawaited(_applyRelayMode());
    }
    _refreshBreadcrumbPolicy();

    final wantsHandsFree = settings.isHandsFree && settings.canTransmit;
    if (wantsHandsFree && !_handsFree) {
      unawaited(startHandsFree());
    } else if (!wantsHandsFree && _handsFree) {
      unawaited(stopHandsFree());
    }
    notifyListeners();
  }

  /// Live radio state (BLE + Wi-Fi Direct), for the app-bar badge.
  LinkStats get linkStats {
    final t = transport;
    if (t is MeshTransport) return t.stats;
    return const LinkStats(
      bleRunning: false,
      bleScanning: false,
      blePeers: 0,
      bleKnownPeers: 0,
      bleStatus: 'off',
      wifiDirectRunning: false,
      wifiDirectSupported: false,
      wifiDirectPeers: 0,
      wifiDirectStatus: 'off',
    );
  }

  /// Short badge text: '2 peers' / 'searching' / 'offline'.
  String get linkLabel => linkStats.label;

  /// Verbose radio state, e.g. 'BLE 1 peer · Wi-Fi Direct connected'.
  String get linkDetail => linkStats.detail;

  // ── State ──────────────────────────────────────────────────────
  TransceiverPhase _phase = TransceiverPhase.idle;
  TransceiverPhase get phase => _phase;

  /// Whether outgoing packets are GPS-stamped (delegates to [settings]).
  bool get gpsEnabled => settings.gpsEnabled;
  set gpsEnabled(bool v) => settings.gpsEnabled = v;

  /// Whether the microphone may be used on this device.
  bool get micEnabled => settings.canTransmit;

  /// Whether incoming messages may be spoken on this device.
  bool get playbackEnabled => settings.canReceive;

  Lang _senderLang = kHindi;
  Lang get senderLang => _senderLang;
  set senderLang(Lang v) {
    if (v == _senderLang) return;
    _senderLang = v;
    notifyListeners();
  }

  Lang _receiverLang = kHindi;
  Lang get receiverLang => _receiverLang;
  set receiverLang(Lang v) {
    if (v == _receiverLang) return;
    _receiverLang = v;
    notifyListeners();
    // Prepare the neural voice for the new receiver language.
    _ensureTtsModels(v);
  }

  String _interimText = '';
  String get interimText => _interimText;

  String? _statusMessage;
  String? get statusMessage => _statusMessage;
  void clearStatusMessage() {
    _statusMessage = null;
    notifyListeners();
  }

  /// Per-launch random prefix for the sequence ID.
  ///
  /// The Sequence ID is the *only* identity an iBFS frame carries, and it is
  /// also the mesh dedup key (NETWORK_PROTOCOL.md §5). If two devices both
  /// counted up from 1 they would each treat the other's first packets as
  /// already-seen duplicates and silently drop them. Seeding the high 16 bits
  /// from a random value keeps concurrent senders apart without changing the
  /// wire format.
  final Random _rng = Random();
  late int _sequenceId = _rng.nextInt(0x10000) << 16;

  /// Typed text to send (fallback when STT is unavailable).
  String _typedText = '';
  String get typedText => _typedText;
  set typedText(String v) {
    _typedText = v;
    notifyListeners();
  }

  // ── Alarm state ────────────────────────────────────────────────

  bool _alarmActive = false;
  bool get alarmActive => _alarmActive;

  Priority _alarmPriority = Priority.emergency;
  Priority get alarmPriority => _alarmPriority;

  /// Text of the message that raised the current alarm.
  String? _alarmText;
  String? get alarmText => _alarmText;

  /// 'SOS' or 'EMERGENCY' — shown in the alarm banner.
  String _alarmLabel = 'EMERGENCY';
  String get alarmLabel => _alarmLabel;

  /// Whether the current alarm came from an explicit SOS packet.
  bool _alarmIsSos = false;
  bool get alarmIsSos => _alarmIsSos;

  /// Who raised the alarm, when the sender transmitted a name.
  String? _alarmSender;
  String? get alarmSender => _alarmSender;

  /// Position attached to the alarm, for the offline map.
  double? _alarmLat;
  double? get alarmLat => _alarmLat;
  double? _alarmLon;
  double? get alarmLon => _alarmLon;

  /// Whether the current alarm carries a plottable position.
  bool get alarmHasPosition => _alarmLat != null && _alarmLon != null;

  /// When the current alarm started, used to ignore stale auto-clear timers
  /// when a second alert arrives while one is already showing.
  DateTime? _alarmStartedAt;
  Timer? _alarmTimer;

  /// How long a routine emergency-keyword alert stays on screen.
  ///
  /// Deliberately short: it is an attention grabber, not a mode. The user can
  /// still read the message in the packet log after it clears.
  static const Duration kEmergencyAlertSeconds = Duration(seconds: 5);

  /// How long an explicit SOS stays up. Longer than a keyword alert because an
  /// SOS is the thing everyone needs to see, and it is re-raised by repeats.
  static const Duration kSosAlertSeconds = Duration(seconds: 20);

  /// Number of devices the last SOS was handed to.
  int _lastSosFanout = 0;
  int get lastSosFanout => _lastSosFanout;

  DateTime? _lastSosSentAt;
  DateTime? get lastSosSentAt => _lastSosSentAt;

  final List<LogEntry> _log = [];
  List<LogEntry> get log => List.unmodifiable(_log);

  // ── Model Download State ───────────────────────────────────────

  bool _modelsDownloading = false;
  bool get modelsDownloading => _modelsDownloading;

  double _modelsDownloadProgress = 0.0;
  double get modelsDownloadProgress => _modelsDownloadProgress;

  String _modelsDownloadStatus = '';
  String get modelsDownloadStatus => _modelsDownloadStatus;

  /// Whether the sender language models are ready for offline STT.
  bool get senderModelsReady =>
      stt.isReady && stt.currentLocale == _senderLang.code;

  // ── TTS Model Download State ──────────────────────────────────

  bool _ttsDownloading = false;
  bool get ttsDownloading => _ttsDownloading;

  double _ttsDownloadProgress = 0.0;
  double get ttsDownloadProgress => _ttsDownloadProgress;

  String _ttsDownloadStatus = '';
  String get ttsDownloadStatus => _ttsDownloadStatus;

  /// Whether the receiver language has a neural TTS engine ready.
  bool get receiverTtsReady => tts.isNeuralReadyFor(_receiverLang);

  /// Download + initialize the neural TTS model for the receiver language.
  Future<bool> downloadReceiverTtsModels() async {
    return _ensureTtsModels(_receiverLang);
  }

  Future<bool> _ensureTtsModels(Lang lang) async {
    // Already loaded for THIS language?
    if (tts.isNeuralReadyFor(lang)) return true;
    // No neural model exists for this language — platform TTS handles it.
    if (!TtsModelDownloader.hasNeuralModel(lang)) return false;
    if (_ttsDownloading) return false;

    _ttsDownloading = true;
    _ttsDownloadProgress = 0.0;
    _ttsDownloadStatus = 'Preparing ${lang.name} voice…';
    notifyListeners();

    // Download if not present.
    var available = await TtsModelDownloader.areModelsAvailable(lang);
    if (!available) {
      available = await TtsModelDownloader.downloadModels(
        lang,
        onProgress: (p) {
          _ttsDownloadProgress = p;
          _ttsDownloadStatus =
              'Downloading ${lang.name} voice… ${(p * 100).toInt()}%';
          notifyListeners();
        },
      );
    }

    _ttsDownloading = false;
    if (available) {
      final loaded = await tts.initNeural(lang);
      _ttsDownloadStatus = loaded
          ? '${lang.name} neural voice ready'
          : '${lang.name} voice unavailable — using platform TTS';
    } else {
      _ttsDownloadStatus = 'Voice download failed — check connection';
    }
    notifyListeners();
    return available;
  }

  /// Download models for the current sender language.
  Future<void> downloadSenderModels() => _downloadModels(_senderLang);

  /// Pre-download models for a language in the background.
  Future<void> predownloadModels(Lang lang) => _downloadModels(lang);

  Future<void> _downloadModels(Lang lang) async {
    if (_modelsDownloading) return;

    _modelsDownloading = true;
    _modelsDownloadProgress = 0.0;
    _modelsDownloadStatus = 'Preparing ${lang.name} models…';
    notifyListeners();

    final success = await stt.prepareModels(
      lang,
      onProgress: (progress) {
        _modelsDownloadProgress = progress;
        _modelsDownloadStatus =
            'Downloading ${lang.name} models… ${(progress * 100).toInt()}%';
        notifyListeners();
      },
    );

    _modelsDownloading = false;
    if (success) {
      final initErr = await stt.init(lang);
      _modelsDownloadStatus = initErr == null
          ? '${lang.name} models ready ✓'
          : 'Load failed: $initErr';
    } else {
      _modelsDownloadStatus = 'Download failed — check connection';
    }
    notifyListeners();
  }

  // ── Mesh Transport ────────────────────────────────────────────

  bool _meshActive = false;

  /// Whether at least one radio is up. `false` only when both radios failed.
  bool get meshActive => _meshActive;

  /// Start (or re-start) the radios. Idempotent — safe to call on a timer.
  Future<bool> enableMesh() async {
    final t = transport;
    if (t is! MeshTransport) return false;
    if (_meshActive) return true;
    final ok = await t.start();
    _meshActive = ok;
    // Both radios down is actionable, not mysterious: say which one refused
    // and what to switch on.
    if (!ok) _statusMessage = t.stats.failureHint ?? _statusMessage;
    notifyListeners();
    return ok;
  }

  /// Number of peers reachable across both radios.
  int get meshPeerCount => linkStats.totalPeers;

  /// Mesh clock state for Settings and the status banner.
  String get meshClockLabel => clock.label;

  /// Learned routes, shown as a routing-health figure.
  int get routeCount => linkStats.routeCount;

  /// Relay path of the last delivered frame, e.g. `4 → 9 → 12`.
  String get lastPathLabel {
    final t = transport;
    if (t is! MeshTransport || t.lastPath.isEmpty) return '';
    return t.lastPath.join(' → ');
  }

  /// Switch between the full transceiver and relay-only duty.
  Future<void> _applyRelayMode() async {
    final t = transport;
    if (t is MeshTransport) {
      await t.setRelayMode(settings.relayMode);
    }
    if (settings.relayMode) {
      await stopHandsFree();
      _statusMessage = 'Relay mode: this phone now only carries traffic for '
          'others — microphone and speaker are off';
    } else {
      _statusMessage = 'Relay mode off: transceiver restored';
    }
    notifyListeners();
  }

  /// Publish this phone's epoch milliseconds; receivers median-filter it.
  Future<void> _sendTimeSync() async {
    final t = transport;
    if (t is! MeshTransport || !t.stats.hasPeers) return;
    final seq = ++_sequenceId;
    try {
      final frame = encodeIbfs(IbfPacket(
        type: PacketType.timeSync,
        priority: Priority.routine,
        language: _senderLang,
        sequenceId: seq,
        text: '${DateTime.now().millisecondsSinceEpoch}',
      ));
      await t.sendBulk(frame);
      _lastClockSync = DateTime.now();
    } catch (_) {
      // No link right now; the next timer tick tries again.
    }
  }

  void _maybeSyncClock() {
    final last = _lastClockSync;
    if (last != null &&
        DateTime.now().difference(last) < const Duration(minutes: 2)) {
      return;
    }
    unawaited(_sendTimeSync());
  }

  // ── Breadcrumbs ────────────────────────────────────────────────

  void _refreshBreadcrumbPolicy() {
    final wanted = settings.breadcrumbsEnabled && !settings.relayMode;
    if (wanted && _breadcrumbTimer == null) {
      _breadcrumbTimer = Timer.periodic(
        const Duration(seconds: 30),
        (_) => unawaited(_recordBreadcrumb()),
      );
      unawaited(_recordBreadcrumb());
    } else if (!wanted && _breadcrumbTimer != null) {
      _breadcrumbTimer?.cancel();
      _breadcrumbTimer = null;
    }
  }

  /// Take one low-accuracy fix and share the recent trail with the mesh.
  Future<void> _recordBreadcrumb() async {
    if (!settings.breadcrumbsEnabled || settings.relayMode) return;
    try {
      final pos = await geo.Geolocator.getCurrentPosition(
        desiredAccuracy: geo.LocationAccuracy.low,
        timeLimit: const Duration(seconds: 12),
      );
      final point = BreadcrumbPoint(
        lat: pos.latitude,
        lon: pos.longitude,
        ts: clock.now().millisecondsSinceEpoch,
      );
      if (!breadcrumbs.addLocal(point)) return;
      notifyListeners();
      await _broadcastBreadcrumbs();
    } catch (_) {
      // No fix (indoors, GPS off) — the next tick tries again.
    }
  }

  Future<void> _broadcastBreadcrumbs() async {
    final t = transport;
    if (t is! MeshTransport || !t.stats.hasPeers) return;
    final trail = breadcrumbs.forKey(BreadcrumbTrail.localKey);
    if (trail.isEmpty) return;
    // A batch of the last 20 fixes keeps the frame well under 512 bytes.
    final batch = trail.length > 20 ? trail.sublist(trail.length - 20) : trail;
    final seq = ++_sequenceId;
    try {
      final frame = encodeIbfs(IbfPacket(
        type: PacketType.breadcrumb,
        priority: Priority.routine,
        language: _senderLang,
        sequenceId: seq,
        text: BreadcrumbTrail.encodeBatch(batch),
        senderName: settings.username.isEmpty ? null : settings.username,
      ));
      await t.sendBulk(frame);
    } catch (_) {
      // Too large or no link; the next point carries a fresh batch.
    }
  }

  /// All trails for the incident map.
  List<List<BreadcrumbPoint>> get breadcrumbLines => breadcrumbs.lines.toList();

  /// Whether a frame can reach another device right now.
  bool get hasReachablePeer => linkStats.hasPeers;

  // ── Hardware (silent) SOS ─────────────────────────────────────

  void _listenSilentSos() {
    EmergencyService.initSilentSosHandler();
    _silentSosSubscription =
        EmergencyService.silentSosTriggered.listen((_) {
      if (!settings.silentSosEnabled) return;
      if (_sosInFlight) return;
      _statusMessage = 'Hardware SOS trigger — sending…';
      notifyListeners();
      unawaited(sendSos(note: 'hardware button'));
    });
    unawaited(EmergencyService.setSilentSosEnabled(settings.silentSosEnabled));
  }

  // ── Operation mode ────────────────────────────────────────────

  bool _handsFree = false;

  /// Whether the mic is currently open in hands-free (phone) mode.
  bool get handsFreeActive => _handsFree;

  /// Open the mic and stream every silence-delimited sentence automatically.
  ///
  /// Returns `false` when the role forbids transmitting or the mic could not
  /// be opened.
  Future<bool> startHandsFree() async {
    if (_handsFree) return true;
    if (!settings.canTransmit) {
      _statusMessage =
          'Receiver-only (TTS) mode: microphone transmission is disabled';
      notifyListeners();
      return false;
    }
    if (_phase == TransceiverPhase.processing) return false;

    _statusMessage = null;
    _interimText = '';
    // The phase deliberately stays `idle` while hands-free is listening.
    // `recording` means "the user is holding the channel", which gates the SOS
    // button, the text field and inbound playback in the UI; hands-free must
    // not lock any of those. [handsFreeActive] is what drives the listening
    // indicator instead.
    notifyListeners();

    if (!stt.isReady || stt.currentLocale != _senderLang.code) {
      unawaited(downloadSenderModels());
      _statusMessage = 'Preparing ${_senderLang.name} speech model — '
          'hands-free transcription improves when it finishes';
      notifyListeners();
    }

    await stt.start(
      localeId: _senderLang.code,
      continuous: true,
      onResult: (text, isFinal) {
        // Live preview while the sentence is still forming.
        if (!isFinal) {
          _interimText = text;
          notifyListeners();
          return;
        }
        // VAD saw its silence window: this sentence is done. Send it.
        _interimText = '';
        _enqueueTranscript(text);
      },
    );

    if (!stt.isListening) {
      _statusMessage = 'Microphone not available — check permissions';
      notifyListeners();
      return false;
    }

    _handsFree = true;
    notifyListeners();
    return true;
  }

  /// Close the hands-free microphone.
  Future<void> stopHandsFree() async {
    if (!_handsFree) return;
    _handsFree = false;
    notifyListeners();
    // Flush anything the VAD was still holding so a half-finished sentence is
    // not silently discarded when the mode is switched off.
    final tail = await stt.stop();
    _phase = TransceiverPhase.idle;
    _interimText = '';
    if (tail.trim().isNotEmpty) await _enqueueTranscript(tail.trim());
    notifyListeners();
  }

  // ── PTT Controls ───────────────────────────────────────────────

  int? _sttStartMs;

  bool get isRecording => _phase == TransceiverPhase.recording;

  /// Whether the mic is live, in either mode. Drives the "listening" indicator.
  bool get isListening => _handsFree || _phase == TransceiverPhase.recording;

  bool get isProcessing => _phase == TransceiverPhase.processing;

  /// Begin recording on PTT press or tap.
  Future<void> startPtt() async {
    if (_phase != TransceiverPhase.idle) return;
    if (!settings.canTransmit) {
      _statusMessage =
          'Receiver-only (TTS) mode: microphone transmission is disabled';
      notifyListeners();
      return;
    }

    _statusMessage = null;
    _phase = TransceiverPhase.recording;
    _interimText = '';
    _sttStartMs = DateTime.now().millisecondsSinceEpoch;
    notifyListeners();

    // Live radio voice wins when enabled: it needs no speech model, works in
    // noise, and is the only path that carries actual voice over the mesh.
    if (settings.liveVoiceEnabled) {
      final started = await _liveVoice.startTx();
      if (started) {
        _liveVoiceTx = true;
        _statusMessage = 'Live voice — transmitting';
        notifyListeners();
        return;
      }
      _statusMessage = _liveVoice.lastError ??
          'Live voice unavailable — using speech recognition';
      notifyListeners();
    }

    // If the offline STT model isn't loaded yet, kick off a download in
    // the background. The hold still captures audio (VAD + fallbacks),
    // so the user is never blocked — but without this, first-time users
    // only ever see "No speech detected" until they find the download
    // button manually.
    if (!stt.isReady || stt.currentLocale != _senderLang.code) {
      downloadSenderModels();
      _statusMessage =
          'Preparing ${_senderLang.name} speech model — voice captured, '
          'transcription improves when the model finishes downloading';
      notifyListeners();
    }

    await stt.start(
      localeId: _senderLang.code,
      onResult: (text, isFinal) {
        _interimText = text;
        notifyListeners();
        if (isFinal && text.trim().isNotEmpty) {
          _enqueueTranscript(text);
        }
      },
    );

    // If stt.start() finished without starting the recorder (e.g. error),
    // reset phase to idle so UI recovers.
    if (!stt.isListening && _phase == TransceiverPhase.recording) {
      _phase = TransceiverPhase.idle;
      _statusMessage = 'Microphone not available — check permissions';
      notifyListeners();
    }
  }

  /// Stop recording on PTT release or second tap; process speech.
  Future<void> stopPtt() async {
    if (_phase != TransceiverPhase.recording) return;

    // A live stream ends the moment the button is released: there is no
    // transcript to process and no note to assemble.
    if (_liveVoiceTx) {
      _liveVoiceTx = false;
      await _liveVoice.stopTx();
      _phase = TransceiverPhase.idle;
      _statusMessage = null;
      notifyListeners();
      return;
    }

    _phase = TransceiverPhase.processing;
    notifyListeners();

    // If recorder was still activating (mic stream setup taking 100-300ms),
    // wait up to 1.5s for recorder to activate so speech is not lost!
    for (var i = 0; i < 15 && !stt.isListening; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }

    if (!stt.isListening) {
      _phase = TransceiverPhase.idle;
      _interimText = '';
      _statusMessage = 'Microphone was not active — tap and speak';
      notifyListeners();
      return;
    }

    // stop() flushes any speech segment still inside the VAD pipeline,
    // so a short utterance spoken right before release is not lost.
    final flushed = await stt.stop();
    final text = (flushed.trim().isNotEmpty ? flushed : _interimText).trim();

    if (text.isNotEmpty) {
      await _enqueueTranscript(text);
    } else {
      _phase = TransceiverPhase.idle;
      _interimText = '';
      // Distinguish "mic never started" from "mic ran but heard nothing".
      // Blanket "speak clearly" advice is wrong when the real cause is a
      // model still downloading or a voice too quiet for the STT model.
      _statusMessage = stt.isReady
          ? 'No transcription — speak louder and closer to the mic'
          : 'Speech model still downloading — tap PTT again in a moment '
              'or type your message below';
      notifyListeners();
    }
  }

  /// Serialises the transmit path.
  ///
  /// Hands-free mode can finish a second sentence while the first is still
  /// being encoded and sent. Queueing here means a sentence is never dropped
  /// and two frames are never built from interleaved state.
  Future<void> _txChain = Future<void>.value();

  // ── Delivery receipts (Packet Type 0x3) ────────────────────────

  /// Frames sent but not yet confirmed by a peer, keyed by sequence ID.
  final Map<int, _PendingAck> _awaitingAck = {};
  Timer? _ackTimer;

  /// How long to wait before re-sending an unconfirmed frame.
  static const Duration kAckRetryInterval = Duration(seconds: 8);

  /// How many times an unconfirmed frame is re-sent before giving up.
  static const int kAckMaxAttempts = 3;

  /// How long an unconfirmed frame is tracked before it is written off.
  static const Duration kAckGiveUpAfter = Duration(seconds: 32);

  /// Start a receipt for a frame that just went onto the radio.
  void _trackAck(int sequenceId, Uint8List frame) {
    // Bound the map: a long PTT session must not accumulate frames forever.
    // The evicted entry must also stop claiming "sending…" in the log.
    if (_awaitingAck.length >= 24) {
      final oldest = _awaitingAck.keys.first;
      _awaitingAck.remove(oldest);
      _updateSentEntry(
        oldest,
        (e) => e.awaitingAck ? e.copyWith(awaitingAck: false) : e,
      );
    }
    _awaitingAck[sequenceId] = _PendingAck(frame);
    _ackTimer ??= Timer.periodic(
      const Duration(seconds: 3),
      (_) => _retryUnconfirmed(),
    );
  }

  /// Re-send frames that no peer has confirmed yet, then write off the ones
  /// that have exhausted their attempts or their time budget.
  void _retryUnconfirmed() {
    final now = DateTime.now();
    for (final entry in _awaitingAck.entries.toList()) {
      final pending = entry.value;
      final age = now.difference(pending.createdAt);

      if (age >= kAckGiveUpAfter || pending.attempts >= kAckMaxAttempts) {
        _awaitingAck.remove(entry.key);
        _updateSentEntry(
          entry.key,
          (e) => e.awaitingAck ? e.copyWith(awaitingAck: false) : e,
        );
        continue;
      }

      if (now.difference(pending.lastAttempt) < kAckRetryInterval) continue;
      pending.attempts++;
      pending.lastAttempt = now;
      unawaited(() async {
        try {
          await transport.send(pending.frame);
        } catch (_) {
          // Still no link; the next tick tries again or gives up.
        }
      }());
    }

    if (_awaitingAck.isEmpty) {
      _ackTimer?.cancel();
      _ackTimer = null;
    }
  }

  /// A peer confirmed [sequenceId]. Update the log and drop any queued copy.
  void _handleAck(int sequenceId) {
    // An acknowledged beacon ping means somebody heard the distress call, so
    // the repeating SOS stops instead of draining the battery. The original
    // sendSos frame is acknowledged separately and does not stop a beacon run
    // started later.
    if (_beaconActive && _beaconSeqs.remove(sequenceId)) {
      stopSosBeacon(acknowledged: true);
    }

    // A receipt for a frame already written off (or replayed from the queue)
    // is still useful: the queued copy is no longer needed either way.
    _awaitingAck.remove(sequenceId);
    storeForward.removeBySequenceId(sequenceId);
    // A receipt is proof the frame arrived, so any "queued / not delivered"
    // note on the entry is no longer true.
    _updateSentEntry(
      sequenceId,
      (e) => e.copyWith(
        acks: e.acks + 1,
        awaitingAck: false,
        clearError: true,
      ),
    );
  }

  /// Replace the most recent sent log entry with [id] after [update].
  void _updateSentEntry(int id, LogEntry Function(LogEntry) update) {
    for (var i = _log.length - 1; i >= 0; i--) {
      final entry = _log[i];
      if (!entry.isSent || entry.id != id) continue;
      final next = update(entry);
      if (identical(next, entry)) return;
      _log[i] = next;
      notifyListeners();
      _persistLog();
      return;
    }
  }

  /// Send a receipt for a received frame.
  ///
  /// Failures are swallowed: the sender retries anyway, and a lost receipt
  /// must never disturb the receive path (or block the alarm behind it).
  Future<void> _sendAck(int ackedSequenceId, {int? destination}) async {
    _sequenceId++;
    try {
      final frame = encodeIbfs(IbfPacket(
        type: PacketType.ack,
        priority: Priority.routine,
        language: _senderLang,
        sequenceId: _sequenceId,
        text: '$ackedSequenceId',
      ));
      // Targeted receipt: the envelope can address the one node that sent the
      // frame, so the receipt stops after N hops instead of flooding the mesh.
      final t = transport;
      if (destination != null && t is MeshTransport) {
        await t.sendTo(frame, destination);
      } else {
        await t.send(frame);
      }
    } catch (_) {
      // No link right now.
    }
  }

  Future<void> _enqueueTranscript(String text) {
    final next = _txChain.then((_) => _processTranscript(text));
    // Keep the chain healthy even if one send throws.
    _txChain = next.catchError((Object e) {
      debugPrint('[TransceiverController] send failed: $e');
    });
    return next;
  }

  /// Process the final transcript and transmit.
  Future<void> _processTranscript(String text) async {
    if (text.trim().isEmpty) {
      if (_phase == TransceiverPhase.processing) {
        _phase = TransceiverPhase.idle;
      }
      _interimText = '';
      notifyListeners();
      return;
    }

    // Ensure phase is processing (Encode stage active)
    _phase = TransceiverPhase.processing;
    notifyListeners();

    final e2eStart = DateTime.now().millisecondsSinceEpoch;
    final sttMs = _sttStartMs != null ? e2eStart - _sttStartMs! : 0;
    _sttStartMs = null;

    // ── Speech / decode timing (RTF benchmark) ──
    final audioMs = stt.lastUtteranceMs > 0 ? stt.lastUtteranceMs : null;
    final decodeMs = stt.lastDecodeMs > 0 ? stt.lastDecodeMs : null;
    final rtf = (audioMs != null && audioMs > 0 && decodeMs != null)
        ? decodeMs / audioMs
        : null;

    // ── Distress detection (ADDITIONAL_FEATURES.md §1) ──
    final isDistress = detectDistress(text, _senderLang.iso639);
    final priority = isDistress ? Priority.emergency : Priority.routine;

    // ── GPS stamping (ADDITIONAL_FEATURES.md §2) ──
    final (lat, lon) = await _stampGps();

    // ── Encode ──
    // Capture the ID: `_sendAck` increments the same counter from the inbound
    // path while this method awaits the radio, so reading `_sequenceId` after
    // an await would track a different frame than the one we sent.
    final seq = ++_sequenceId;
    final packet = IbfPacket(
      type: PacketType.pttVoice,
      priority: priority,
      language: _senderLang,
      sequenceId: seq,
      text: text,
      latitude: lat,
      longitude: lon,
      // Username travels with every frame so the receiver knows who spoke.
      senderName: settings.username.isEmpty ? null : settings.username,
    );

    final frame = encodeIbfs(packet);

    // Brief visual pause so the user sees the Encode stage light up
    await Future<void>.delayed(const Duration(milliseconds: 150));

    // ── Transmit ──
    _phase = TransceiverPhase.transmitting;
    notifyListeners();

    int transferMs;
    try {
      transferMs = await transport.send(frame);
    } catch (e) {
      // Queue for store-and-forward (ADDITIONAL_FEATURES.md §3).
      final reason = e is StateError ? e.message : e.toString();
      storeForward.enqueue(frame, sequenceId: seq);
      _addLog(LogEntry(
        id: seq,
        timestamp: DateTime.now(),
        isSent: true,
        text: text,
        langName: _senderLang.name,
        priority: priority,
        sttMs: sttMs,
        lat: lat,
        lon: lon,
        audioMs: audioMs,
        decodeMs: decodeMs,
        rtf: rtf,
        senderName: settings.username.isEmpty ? null : settings.username,
        error: 'Not delivered — $reason\nQueued '
            '(${storeForward.pendingCount}) for automatic retry',
      ));
      _phase = TransceiverPhase.idle;
      _interimText = '';
      notifyListeners();
      return;
    }

    final e2eMs = DateTime.now().millisecondsSinceEpoch - e2eStart;

    // Handed to the radio is not the same as heard: wait for a receipt and
    // re-send a few times before calling it sent.
    _trackAck(seq, frame);

    _addLog(LogEntry(
      id: seq,
      timestamp: DateTime.now(),
      isSent: true,
      text: text,
      langName: _senderLang.name,
      priority: priority,
      sttMs: sttMs,
      transferMs: transferMs,
      e2eMs: e2eMs,
      lat: lat,
      lon: lon,
      audioMs: audioMs,
      decodeMs: decodeMs,
      rtf: rtf,
      senderName: settings.username.isEmpty ? null : settings.username,
      awaitingAck: true,
    ));

    _phase = TransceiverPhase.idle;
    _interimText = '';
    notifyListeners();
  }

  /// Best-effort GPS fix for an outgoing frame.
  ///
  /// Never throws and never blocks for long: an SOS must not wait on a
  /// satellite, and a missing fix is better than a late alert.
  Future<(double?, double?)> _stampGps({
    Duration timeout = const Duration(seconds: 5),
  }) async {
    if (!settings.gpsEnabled) return (null, null);
    try {
      final pos = await geo.Geolocator.getCurrentPosition(
        desiredAccuracy: geo.LocationAccuracy.low,
        timeLimit: timeout,
      );
      return (pos.latitude, pos.longitude);
    } catch (_) {
      return (null, null);
    }
  }

  // ── SOS + Emergency Standby ────────────────────────────────────

  bool _standbyActive = false;

  /// Whether Android is keeping Sahara alive in the background, so SOS
  /// signals are received even with the app swiped off the recents list.
  bool get standbyActive => _standbyActive;

  bool _dndAccess = false;

  /// Whether the user granted Do Not Disturb access.
  ///
  /// The alarm tone is exempt from DND either way; this access is what also
  /// lifts DND so the *spoken* message is audible.
  bool get dndAccess => _dndAccess;

  bool _batteryExempt = true;

  /// Whether the app is exempt from battery optimisation. Without it, OEM
  /// battery savers can kill standby and with it SOS reception.
  bool get batteryExempt => _batteryExempt;

  bool _sosInFlight = false;
  bool get sosInFlight => _sosInFlight;

  /// Re-read native emergency state (called when the app resumes, so status
  /// updates after the user returns from a settings screen).
  Future<void> refreshEmergencyState() async {
    final standby = await EmergencyService.isStandbyRunning();
    final dnd = await EmergencyService.hasDndAccess();
    final battery = await EmergencyService.isIgnoringBatteryOptimizations();
    if (standby == _standbyActive &&
        dnd == _dndAccess &&
        battery == _batteryExempt) {
      return;
    }
    _standbyActive = standby;
    _dndAccess = dnd;
    _batteryExempt = battery;
    notifyListeners();
  }

  /// Turn on background standby. Returns `true` when active.
  Future<bool> enableStandby() async {
    final ok = await EmergencyService.startStandby();
    if (ok != _standbyActive) {
      _standbyActive = ok;
      notifyListeners();
    }
    return ok;
  }

  Future<void> disableStandby() async {
    await EmergencyService.stopStandby();
    _standbyActive = false;
    notifyListeners();
  }

  Future<void> openDndSettings() => EmergencyService.openDndSettings();

  Future<void> openBatterySettings() => EmergencyService.openBatterySettings();

  /// Broadcast an SOS to every nearby device.
  ///
  /// This is deliberately not a priority flag on a normal message: an SOS is
  /// [PacketType.silentSos], which every receiver treats as "raise the alarm",
  /// including receivers whose app is not on screen.
  ///
  /// The pre-set medical telemetry from Settings is appended to the message so
  /// responders receive blood group and emergency contacts in the same packet
  /// rather than having to ask for them.
  ///
  /// Returns `true` when at least one device was reached. When nothing is in
  /// range the frame is queued and re-sent automatically on reconnect.
  Future<bool> sendSos({String? note}) async {
    if (_sosInFlight) return false;
    _sosInFlight = true;
    notifyListeners();

    try {
      // Shorter GPS budget than a normal message: alert first, locate second.
      final (lat, lon) = await _stampGps(
        timeout: const Duration(seconds: 3),
      );

      final seq = ++_sequenceId;
      final buffer = StringBuffer('SOS');
      final trimmedNote = note?.trim() ?? '';
      if (trimmedNote.isNotEmpty) buffer.write(' — $trimmedNote');
      final medical = settings.medicalSummary;
      if (medical != null) buffer.write(' | $medical');
      // Battery level is triage information: a responder needs to know whether
      // the phone will still be reachable in an hour.
      final bat = batteryPercent;
      if (bat != null) buffer.write(' | Bat $bat%');
      final text = buffer.toString();

      final packet = IbfPacket(
        type: PacketType.silentSos,
        priority: Priority.emergency,
        language: _senderLang,
        sequenceId: seq,
        text: text,
        latitude: lat,
        longitude: lon,
        senderName: settings.username.isEmpty ? null : settings.username,
      );
      final frame = encodeIbfs(packet);

      int fanout;
      try {
        fanout = await transport.send(frame);
      } catch (e) {
        final reason = e is StateError ? e.message : e.toString();
        storeForward.enqueue(frame, sequenceId: seq);
        _lastSosFanout = 0;
        _lastSosSentAt = DateTime.now();
        _statusMessage = 'SOS queued — $reason. It will be sent automatically '
            'as soon as a device is in range.';
        _addLog(LogEntry(
          id: seq,
          timestamp: DateTime.now(),
          isSent: true,
          text: text,
          langName: _senderLang.name,
          priority: Priority.emergency,
          lat: lat,
          lon: lon,
          sos: true,
          senderName: settings.username.isEmpty ? null : settings.username,
          error: 'Not delivered — $reason\nQueued '
              '(${storeForward.pendingCount}) for automatic retry',
        ));
        return false;
      }

      _lastSosFanout = fanout;
      _lastSosSentAt = DateTime.now();
      _statusMessage =
          fanout == 1 ? 'SOS sent to 1 device' : 'SOS sent to $fanout devices';
      _trackAck(seq, frame);
      _addLog(LogEntry(
        id: seq,
        timestamp: DateTime.now(),
        isSent: true,
        text: text,
        langName: _senderLang.name,
        priority: Priority.emergency,
        lat: lat,
        lon: lon,
        sos: true,
        senderName: settings.username.isEmpty ? null : settings.username,
        awaitingAck: true,
      ));
      return fanout > 0;
    } finally {
      _sosInFlight = false;
      notifyListeners();
    }
  }

  // ── Structured coordination + SOS beacon ───────────────────────

  /// Reports heard over the mesh (and sent from here).
  ///
  /// Exposed through the controller rather than as a separate provider so the
  /// existing `Consumer<TransceiverController>` screens repaint on board
  /// changes without another provider to wire up.
  final IncidentBoard _incidents = IncidentBoard();
  IncidentBoard get incidents => _incidents;

  /// Camps and their needs/supplies, gossiped over the mesh.
  final ReliefLedger _relief = ReliefLedger();
  ReliefLedger get relief => _relief;

  /// Missing-person records, gossiped over the mesh (text only).
  final MissingRegistry _missing = MissingRegistry();
  MissingRegistry get missing => _missing;

  /// Early-warning alerts fetched while a connection exists.
  List<FeedAlert> _alerts = const [];
  List<FeedAlert> get alerts => List.unmodifiable(_alerts);

  bool _alertsLoading = false;
  bool get alertsLoading => _alertsLoading;

  String? _alertFeedError;
  String? get alertFeedError => _alertFeedError;

  /// RSSI per advertising peer, for coarse proximity homing.
  List<PeerSignal> get peerSignals {
    final t = transport;
    return t is MeshTransport ? t.peerSignals : const <PeerSignal>[];
  }

  final VoiceNoteAssembler _voiceAssembler = VoiceNoteAssembler();
  final AudioPlayer _notePlayer = AudioPlayer();

  /// Real-time Codec2 voice (native audio path).
  final LiveVoice _liveVoice = LiveVoice.instance;
  StreamSubscription<LiveVoiceFrame>? _liveVoiceSub;
  Timer? _liveVoiceRxTimer;
  bool _liveVoiceTx = false;

  /// Whether this phone is currently streaming real-time voice.
  bool get liveVoiceTx => _liveVoiceTx;

  /// Whether live voice is usable here, for the Settings hint.
  bool get liveVoiceAvailable => _liveVoice.isAvailable;
  String? get liveVoiceError => _liveVoice.lastError;
  AudioRecorder? _noteRecorder;
  String? _notePath;
  bool _noteRecording = false;

  /// Whether a voice note is currently being recorded on this phone.
  bool get voiceNoteRecording => _noteRecording;

  /// Latest real battery percentage, or null when no reading is available.
  int? get batteryPercent =>
      (battery?.hasReading ?? false) ? battery!.level : null;

  /// Beacon pings sent before the run gives up waiting for a receipt.
  static const int kBeaconMaxRepeats = 12;

  /// Time between beacon pings. Slow enough to leave the battery and the mesh
  /// usable, fast enough that a responder homing in sees a new fix.
  static const Duration kBeaconInterval = Duration(seconds: 45);

  bool _beaconActive = false;
  bool get beaconActive => _beaconActive;

  int _beaconSent = 0;
  int get beaconSent => _beaconSent;

  String? _beaconIncidentId;
  Timer? _beaconTimer;
  final Set<int> _beaconSeqs = {};

  /// 4 hex characters, enough to keep incidents apart on one mesh without
  /// spending payload bytes on a UUID.
  String _newIncidentId() =>
      _rng.nextInt(0x10000).toRadixString(16).toUpperCase().padLeft(4, '0');

  /// Encode + transmit one structured report, log it, and track its receipt.
  Future<_EmitResult> _emitReport({
    required PacketType type,
    required Priority priority,
    required IncidentReport report,
    required String logText,
    bool sos = false,
    bool logEntry = true,
  }) async {
    final (lat, lon) = await _stampGps(timeout: const Duration(seconds: 4));
    final seq = ++_sequenceId;
    final senderName = settings.username.isEmpty ? null : settings.username;
    final outgoing = report.copyWith(
      lat: lat,
      lon: lon,
      sender: senderName,
      battery: batteryPercent,
    );

    final frame = encodeIbfs(IbfPacket(
      type: type,
      priority: priority,
      language: _senderLang,
      sequenceId: seq,
      text: outgoing.toWireJson(),
      latitude: lat,
      longitude: lon,
      senderName: senderName,
    ));

    int transferMs;
    try {
      transferMs = await transport.send(frame);
    } catch (e) {
      final reason = e is StateError ? e.message : e.toString();
      storeForward.enqueue(frame, sequenceId: seq);
      _incidents.upsert(outgoing);
      if (logEntry) {
        _addLog(LogEntry(
          id: seq,
          timestamp: DateTime.now(),
          isSent: true,
          text: logText,
          langName: _senderLang.name,
          priority: priority,
          lat: lat,
          lon: lon,
          sos: sos,
          senderName: senderName,
          error: 'Not delivered — $reason\nQueued '
              '(${storeForward.pendingCount}) for automatic retry',
        ));
        _statusMessage = 'Queued — no peer in range yet';
        notifyListeners();
      }
      return _EmitResult(false, seq);
    }

    _trackAck(seq, frame);
    _incidents.upsert(outgoing);
    if (logEntry) {
      _addLog(LogEntry(
        id: seq,
        timestamp: DateTime.now(),
        isSent: true,
        text: logText,
        langName: _senderLang.name,
        priority: priority,
        transferMs: transferMs,
        lat: lat,
        lon: lon,
        sos: sos,
        senderName: senderName,
        awaitingAck: true,
      ));
    } else {
      notifyListeners();
    }
    return _EmitResult(transferMs > 0, seq);
  }

  /// "I am safe" / "not safe" check-in with a head count.
  Future<bool> sendCheckIn({
    bool safe = true,
    int peopleHere = 1,
    int peopleMissing = 0,
    String? note,
  }) async {
    final report = IncidentReport(
      kind: IncidentKind.checkIn,
      incidentId: _newIncidentId(),
      timestamp: DateTime.now(),
      safe: safe,
      peopleSafe: safe ? peopleHere.clamp(0, 999) : 0,
      peopleMissing: peopleMissing.clamp(0, 999),
      severity: safe ? 0 : 3,
      note: note?.trim() ?? '',
    );
    final result = await _emitReport(
      type: PacketType.checkIn,
      priority: safe ? Priority.routine : Priority.emergency,
      report: report,
      logText: report.summaryLine,
    );
    return result.sent;
  }

  /// Structured triage record: victims, injured, needs, severity.
  Future<bool> sendStatusReport({
    int victims = 0,
    int injured = 0,
    Set<Need> needs = const <Need>{},
    int severity = 1,
    String? note,
    String? incidentId,
  }) async {
    final sev = severity.clamp(0, 3);
    final report = IncidentReport(
      kind: IncidentKind.status,
      incidentId: incidentId ?? _newIncidentId(),
      timestamp: DateTime.now(),
      severity: sev,
      victims: victims.clamp(0, 9999),
      injured: injured.clamp(0, 9999),
      needs: needs,
      note: note?.trim() ?? '',
    );
    final result = await _emitReport(
      type: PacketType.statusReport,
      priority: sev >= 3
          ? Priority.emergency
          : sev >= 2
              ? Priority.high
              : Priority.routine,
      report: report,
      logText: report.summaryLine,
    );
    return result.sent;
  }

  /// Early warning. The message is spoken and alarmed on every receiver, with
  /// no internet needed at either end.
  Future<bool> sendWarning({
    required String message,
    int severity = 2,
    double radiusKm = 10,
    int expiresMinutes = 180,
  }) async {
    final text = message.trim();
    if (text.isEmpty) return false;
    final now = DateTime.now();
    final report = IncidentReport(
      kind: IncidentKind.warning,
      incidentId: _newIncidentId(),
      timestamp: now,
      severity: severity.clamp(0, 3),
      note: text,
      radiusKm: radiusKm,
      expiresAt: now.add(Duration(minutes: expiresMinutes.clamp(1, 1440))),
    );
    final result = await _emitReport(
      type: PacketType.alert,
      priority: Priority.emergency,
      report: report,
      logText: report.summaryLine,
    );
    return result.sent;
  }

  /// Tell a victim's phone which team is coming and when.
  Future<bool> assignResponder({
    required String incidentId,
    required String team,
    required int etaMinutes,
  }) async {
    final trimmedTeam = team.trim();
    if (incidentId.isEmpty || trimmedTeam.isEmpty) return false;
    final eta = etaMinutes.clamp(0, 1440);
    final report = IncidentReport(
      kind: IncidentKind.assignment,
      incidentId: incidentId,
      timestamp: DateTime.now(),
      severity: 2,
      status: IncidentStatus.assigned,
      assignedTeam: trimmedTeam,
      etaMinutes: eta,
    );
    // Update the local board immediately; the mesh copy informs the victim.
    _incidents.applyAssignment(
      incidentId: incidentId,
      team: trimmedTeam,
      etaMinutes: eta,
    );
    final result = await _emitReport(
      type: PacketType.assignment,
      priority: Priority.high,
      report: report,
      logText: report.summaryLine,
    );
    return result.sent;
  }

  /// Start the repeating SOS beacon.
  ///
  /// One SOS is easy to miss: the phone may be in a pocket, the first frame may
  /// collide, or the victim may be moving. The beacon repeats the same incident
  /// with a fresh GPS fix until a receipt arrives or the run is exhausted.
  Future<bool> startSosBeacon({String? note}) async {
    if (_beaconActive) return false;
    _beaconActive = true;
    _beaconSent = 0;
    _beaconIncidentId = _newIncidentId();
    _beaconSeqs.clear();
    _statusMessage = 'SOS beacon started — repeats until acknowledged';
    notifyListeners();

    await _sendBeaconPing(note: note, first: true);

    // A phone already low on power halves the beacon rate instead of dying in
    // twenty minutes.
    final interval = (battery?.shouldThrottle ?? false)
        ? const Duration(seconds: 90)
        : kBeaconInterval;
    _beaconTimer?.cancel();
    _beaconTimer = Timer.periodic(interval, (_) {
      unawaited(_sendBeaconPing(note: note));
    });
    return true;
  }

  /// Stop the beacon. [acknowledged] is set when a receipt caused the stop.
  void stopSosBeacon({bool acknowledged = false}) {
    if (!_beaconActive && _beaconTimer == null) return;
    _beaconActive = false;
    _beaconTimer?.cancel();
    _beaconTimer = null;
    if (acknowledged) {
      _statusMessage = 'SOS acknowledged — beacon stopped';
      _addLog(LogEntry(
        id: -1,
        timestamp: DateTime.now(),
        isSent: false,
        text: '[SOS acknowledged — beacon stopped]',
        langName: '—',
        priority: Priority.routine,
      ));
    }
    notifyListeners();
  }

  Future<void> _sendBeaconPing({String? note, bool first = false}) async {
    if (!_beaconActive) return;
    if (_beaconSent >= kBeaconMaxRepeats) {
      stopSosBeacon();
      _statusMessage = 'Beacon finished — no delivery receipt received';
      notifyListeners();
      return;
    }
    _beaconSent++;
    final incidentId = _beaconIncidentId ??= _newIncidentId();

    final buffer = StringBuffer('SOS');
    final trimmed = note?.trim() ?? '';
    if (trimmed.isNotEmpty) buffer.write(' — $trimmed');
    buffer.write(' · beacon $_beaconSent/$kBeaconMaxRepeats');
    final bat = batteryPercent;
    if (bat != null) buffer.write(' · Bat $bat%');
    final medical = settings.medicalSummary;
    if (medical != null) buffer.write(' | $medical');

    final report = IncidentReport(
      kind: IncidentKind.sos,
      incidentId: incidentId,
      timestamp: DateTime.now(),
      severity: 3,
      note: buffer.toString(),
      safe: false,
    );

    final result = await _emitReport(
      type: PacketType.silentSos,
      priority: Priority.emergency,
      report: report,
      logText: report.summaryLine,
      sos: true,
      logEntry: first,
    );
    if (result.sent) _beaconSeqs.add(result.seq);
    notifyListeners();
  }

  /// Raise the alarm overlay and the native loud alert.
  ///
  /// Not awaited by the inbound path: the alarm must never block the next
  /// packet from being processed, and a second SOS arriving during an alert
  /// extends it rather than being dropped.
  /// Starts the alarm and returns its start stamp, so a later call can tell
  /// whether this alarm is still the one on screen before updating its text.
  DateTime _raiseAlarm(IbfPacket packet, String displayText) {
    final startedAt = DateTime.now();
    _alarmStartedAt = startedAt;
    _alarmActive = true;
    _alarmPriority = packet.priority;
    _alarmIsSos = packet.isSos;
    _alarmLabel = packet.alertLabel;
    _alarmText = displayText;
    _alarmSender = packet.senderName;
    _alarmLat = packet.latitude;
    _alarmLon = packet.longitude;
    notifyListeners();

    // Native alert first: a loud alarm on the alarm stream, a repeating
    // vibration and a full-screen notification. This is what makes the SOS
    // audible when no widget tree is mounted, on silent mode, and through
    // Do Not Disturb.
    unawaited(EmergencyService.raiseAlarm(
      text: displayText,
      from: packet.senderName ?? packet.alertLabel,
    ));

    _alarmTimer?.cancel();
    _alarmTimer = Timer(
      packet.isSos ? kSosAlertSeconds : kEmergencyAlertSeconds,
      () {
        // Ignore a stale timer if a newer alert replaced this one.
        if (_alarmStartedAt != startedAt) return;
        _alarmActive = false;
        notifyListeners();
        unawaited(EmergencyService.clearAlarm());
      },
    );

    return startedAt;
  }

  // ── Receive Path ───────────────────────────────────────────────

  /// Inbound frames are handled strictly one at a time. Frames can arrive
  /// back-to-back on PTT release, and overlapping TTS calls would speak over
  /// each other.
  Future<void> _inboundChain = Future<void>.value();

  void _listenInbound() {
    transport.incoming.listen((bytes) {
      _inboundChain = _inboundChain.then((_) => _handleInbound(bytes));
    });
  }

  Future<void> _handleInbound(Uint8List bytes) async {
    final e2eStart = DateTime.now().millisecondsSinceEpoch;

    // ── Decode ──
    IbfPacket packet;
    try {
      packet = decodeIbfs(bytes);
    } catch (e) {
      _addLog(LogEntry(
        id: -1,
        timestamp: DateTime.now(),
        isSent: false,
        text: '[Corrupt frame dropped]',
        langName: '—',
        priority: Priority.routine,
        error: e.toString(),
      ));
      return;
    }

    // ── Delivery receipts ──
    // A receipt is machinery, not a message: it is never logged, spoken or
    // alarmed. Any other valid frame is confirmed so the sender can stop
    // retrying, and the receipt is sent before the slow playback path.
    if (packet.isAck) {
      final acked = packet.ackedSequenceId;
      if (acked != null) _handleAck(acked);
      return;
    }

    // ── Mesh clock ──
    // No receipt and no log line: a clock sample is infrastructure, and
    // acknowledging every one would add chatter to a constrained radio.
    if (packet.type == PacketType.timeSync) {
      final epoch = int.tryParse(packet.text.trim());
      if (epoch != null) {
        clock.observe(epoch);
        _lastClockSync = DateTime.now();
        notifyListeners();
      }
      return;
    }

    // ── Breadcrumb batches ──
    if (packet.type == PacketType.breadcrumb) {
      final points = BreadcrumbTrail.decodeBatch(packet.text);
      if (points.isNotEmpty) {
        final merged = breadcrumbs.merge(
          packet.senderName ?? 'Unknown',
          points,
        );
        if (merged > 0) notifyListeners();
      }
      return;
    }

    // ── Real-time Codec2 voice ──
    // Deliberately handled before the receipt path: at ~17 packets per second
    // acknowledging every frame would crowd the same radio the audio needs,
    // and a lost 60 ms burst is not worth retransmitting.
    if (packet.type == PacketType.voiceFrame) {
      _onIncomingVoiceFrame(packet);
      return;
    }

    final int? replyTo = transport is MeshTransport
        ? (transport as MeshTransport).lastOrigin
        : null;
    unawaited(_sendAck(packet.sequenceId, destination: replyTo));

    // ── Voice-note fallback chunks ──
    if (packet.type == PacketType.voiceChunk) {
      final audio = _voiceAssembler.accept(packet.text);
      if (audio != null) await _receiveVoiceNote(audio, packet);
      return;
    }

    // ── Relief ledger gossip ──
    if (packet.type == PacketType.reliefUpdate) {
      final entry = ReliefEntry.tryParse(packet.text);
      if (entry != null && _relief.upsert(entry)) {
        final short = entry.shortfall.entries
            .map((e) => '${e.value} ${e.key.label.toLowerCase()}')
            .join(', ');
        _addLog(LogEntry(
          id: packet.sequenceId,
          timestamp: DateTime.now(),
          isSent: false,
          text: 'Camp ${entry.name}: '
              '${short.isEmpty ? 'supplies cover needs' : 'needs $short'}',
          langName: packet.language.name,
          priority: Priority.routine,
          senderName: packet.senderName,
        ));
      }
      return;
    }

    // ── Missing-person records ──
    if (packet.type == PacketType.missingPerson) {
      final person = MissingPerson.tryParse(packet.text);
      if (person != null && _missing.upsert(person)) {
        _addLog(LogEntry(
          id: packet.sequenceId,
          timestamp: DateTime.now(),
          isSent: false,
          text: 'Missing: ${person.name}'
              '${person.age == null ? '' : ', ${person.age}'}',
          langName: packet.language.name,
          priority: Priority.high,
          senderName: packet.senderName,
        ));
      }
      return;
    }

    // ── Sender identity (feature: username over iBFS) ──
    // `displayText` already carries the "[Name] " prefix when the sender
    // transmitted one, so both the log and the alarm show who spoke.

    // ── Structured reports ──
    // Status / check-in / warning / assignment packets carry a JSON body. It is
    // parsed here so the board, the log line and the spoken sentence all use
    // the human summary instead of reading JSON aloud.
    final structured = IncidentReport.tryFromPacket(packet);
    if (structured != null) _incidents.upsert(structured);
    final baseText = structured?.summaryLine ?? packet.displayText;

    // ── Alarm first ──
    // Raised before translation and TTS on purpose. Those can take seconds
    // (model lookup, a 3 s translation timeout, then the whole sentence being
    // spoken), and an SOS siren that arrives after a spoken paragraph is a
    // safety bug. The translated line is appended below once it exists.
    final DateTime? alarmStamp =
        packet.raisesAlarm ? _raiseAlarm(packet, baseText) : null;

    // ── Half-duplex discipline ──
    // Push-to-talk is half duplex: while this device is recording, processing
    // or transmitting, the incoming voice is logged but NOT played, otherwise
    // the speaker would be picked up by our own microphone and immediately
    // re-transmitted.
    //
    // Hands-free is deliberately excluded: there is no "on air" state to
    // suppress against, and silencing every incoming message while the mic is
    // open would turn the phone mode into a one-way channel. The feedback loop
    // is broken at the other end instead — capture is muted for exactly as long
    // as the incoming voice is playing.
    final bool busyTransmitting = !_handsFree &&
        (_phase == TransceiverPhase.recording ||
            _phase == TransceiverPhase.processing ||
            _phase == TransceiverPhase.transmitting);

    // ── Language handling + translation + neural TTS (ARCHITECTURE.md §2.4) ──
    //
    // Translation runs between decode and TTS: a Kannada message is spoken in
    // the receiver's language when that pair's on-device model is present.
    // `translate()` never downloads synchronously — it kicks a download off in
    // the background and returns null, so this message is spoken in its
    // original language and the *next* one is translated. The whole step is
    // also bounded by a timeout, because a cross-language packet must not
    // delay an alarm.
    //
    // Anything unsupported (an ML Kit-less language, models not downloaded yet,
    // non-Android) falls back to the original text with a note, never to a
    // dropped message.
    final bool sameLang = packet.language.iso639 == _receiverLang.iso639;
    String? translated;
    if (!sameLang && settings.translationEnabled) {
      translated = await translator
          .translate(
            structured?.translatableText ?? packet.text,
            packet.language,
            _receiverLang,
          )
          .timeout(const Duration(seconds: 3), onTimeout: () => null);
      if (translated != null && translated.trim().isEmpty) translated = null;
      // Capture what was actually said; a one-word result is worse than the
      // original for a distres message, so require a plausible translation.
      if (translated != null && translated.trim().length < 2) translated = null;
    }

    final String displayText = baseText;
    final String spokenText =
        translated ?? structured?.summaryLine ?? packet.text;
    final Lang ttsLang = translated != null ? _receiverLang : packet.language;
    final String? translationNote = sameLang
        ? null
        : translated != null
            ? null
            : settings.translationEnabled
                ? 'Message in ${packet.language.name} — translation model not ready'
                : 'Message in ${packet.language.name} — translation off';

    // Skipped while we are on air so a voice download never delays the next
    // packet; the log still shows the text either way.
    if (!busyTransmitting) await _ensureTtsModels(ttsLang);

    final int? ttsMs;
    if (!settings.canReceive) {
      // Sender-only (STT) role: log it, stay silent.
      ttsMs = null;
    } else if (busyTransmitting) {
      // Received while we were on air — show it, stay silent.
      ttsMs = null;
    } else {
      // For an SOS, let the alarm tone land first: the burst grabs attention
      // and the spoken message then gets through the gaps.
      if (packet.isSos) {
        await Future<void>.delayed(const Duration(milliseconds: 1500));
      }

      // Hands-free keeps the mic open while we speak, so our own voice would
      // be captured and sent back. Mute capture for the duration.
      final counterMute = _handsFree;
      if (counterMute) stt.muteCapture(true);
      final ttsStart = DateTime.now().millisecondsSinceEpoch;
      try {
        await tts.speak(spokenText,
            lang: ttsLang, emergency: packet.raisesAlarm);
      } finally {
        if (counterMute) stt.muteCapture(false);
      }
      ttsMs = DateTime.now().millisecondsSinceEpoch - ttsStart;
    }

    final e2eMs = DateTime.now().millisecondsSinceEpoch - e2eStart;

    _addLog(LogEntry(
      id: packet.sequenceId,
      timestamp: DateTime.now(),
      isSent: false,
      text: displayText,
      langName: sameLang
          ? packet.language.name
          : '${packet.language.name} → ${_receiverLang.name}',
      priority: packet.priority,
      ttsMs: ttsMs,
      e2eMs: e2eMs,
      lat: packet.latitude,
      lon: packet.longitude,
      sos: packet.isSos,
      senderName: packet.senderName,
      error: translationNote,
      translated: translated,
    ));

    // ── Alarm text, translated ──
    // The siren already fired above; this only enriches the caption so a
    // responder who cannot read the sender's language can still act on it.
    // Guarded by the start stamp: a newer alert may have replaced this one
    // while the sentence was being spoken.
    if (alarmStamp != null &&
        translated != null &&
        _alarmActive &&
        _alarmStartedAt == alarmStamp) {
      _alarmText = '$baseText\n$translated';
      notifyListeners();
    }
  }

  /// Manually dismiss the alarm (also silences the native alert).
  void dismissAlarm() {
    _alarmTimer?.cancel();
    _alarmTimer = null;
    _alarmActive = false;
    _alarmText = null;
    _alarmSender = null;
    notifyListeners();
    unawaited(EmergencyService.clearAlarm());
  }

  // ── Log persistence ────────────────────────────────────────────

  void _addLog(LogEntry entry) {
    _log.add(clock.synced ? entry.copyWith(timestamp: clock.now()) : entry);
    notifyListeners();
    _persistLog();
  }

  Future<void> _persistLog() async {
    final prefs = await SharedPreferences.getInstance();
    final json = _log.map((e) => e.toJson()).toList();
    await prefs.setString('itantra_log', jsonEncode(json));
  }

  /// Load persisted log from disk.
  Future<void> loadLog() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('itantra_log');
    if (raw == null) return;
    try {
      final list = jsonDecode(raw) as List;
      _log.clear();
      _log.addAll(list.map((j) => LogEntry.fromJson(j as Map<String, dynamic>)));
      notifyListeners();
    } catch (_) {
      // Corrupted log — start fresh.
    }
  }

  /// Send typed text directly (bypasses STT).
  Future<void> sendTypedText(String text) async {
    if (text.trim().isEmpty) return;
    if (_phase != TransceiverPhase.idle) return;

    _typedText = '';
    notifyListeners();
    await _enqueueTranscript(text.trim());
  }

  /// Number of queued messages waiting for peer reconnection.
  int get queuedCount => storeForward.pendingCount;
  bool get hasQueuedMessages => storeForward.hasPending;

  /// Clear the packet log.
  Future<void> clearLog() async {
    _log.clear();
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('itantra_log');
  }

  // ── Cache maintenance (Settings) ───────────────────────────────

  /// Delete cached audio clips, the stored message log and the pending
  /// store-and-forward queue.
  ///
  /// Downloaded AI models are deliberately **kept**: re-downloading a 150 MB
  /// speech model in a disaster zone is exactly what this app exists to avoid.
  /// A separate switch in Settings removes translation models explicitly.
  Future<CacheClearReport> clearCaches({
    bool dropTranslationModels = false,
    bool dropSpeechModels = false,
  }) async {
    var clipBytes = 0;
    var clipCount = 0;

    try {
      final tmp = await getTemporaryDirectory();
      await for (final entity in tmp.list()) {
        if (entity is! File) continue;
        final name = entity.uri.pathSegments.last;
        if (!name.startsWith('itantra_tts_')) continue;
        try {
          clipBytes += await entity.length();
          await entity.delete();
          clipCount++;
        } catch (_) {
          // A clip still being played cannot be removed; it will be
          // overwritten on the next synthesis.
        }
      }
    } catch (e) {
      debugPrint('[TransceiverController] cache cleanup: $e');
    }

    final logEntries = _log.length;
    await clearLog();
    storeForward.clear();

    if (dropTranslationModels) {
      await translator.purgeModels();
    }

    if (dropSpeechModels) {
      // Drop downloaded STT/TTS model files; they re-download on demand.
      try {
        final docs = await getApplicationDocumentsDirectory();
        final modelsDir = Directory('${docs.path}/models');
        if (await modelsDir.exists()) {
          await modelsDir.delete(recursive: true);
        }
      } catch (e) {
        debugPrint('[TransceiverController] model purge: $e');
      }
    }

    _statusMessage = 'Cleared $clipCount cached clip'
        '${clipCount == 1 ? '' : 's'} and $logEntries log entries';
    notifyListeners();

    return CacheClearReport(
      clipCount: clipCount,
      clipBytes: clipBytes,
      logEntries: logEntries,
    );
  }

  // ── Relief, missing persons, alerts, voice notes, homing ──

  /// Fetch every configured RSS/Atom feed once. Never polls in the background.
  Future<bool> refreshAlerts() async {
    if (_alertsLoading) return false;
    _alertsLoading = true;
    _alertFeedError = null;
    notifyListeners();
    final fetcher = AlertFeedFetcher();
    try {
      final result = await fetcher.fetchAll(settings.alertFeeds);
      _alerts = result.alerts;
      _alertFeedError = result.hasFailures ? result.failureSummary : null;
      _statusMessage = result.alerts.isEmpty
          ? 'No alerts found in the configured feeds'
          : '${result.alerts.length} alert'
              '${result.alerts.length == 1 ? '' : 's'} fetched';
      return true;
    } catch (e) {
      _alertFeedError = e.toString();
      return false;
    } finally {
      fetcher.close();
      _alertsLoading = false;
      notifyListeners();
    }
  }

  /// Rebroadcast a fetched alert over the mesh as a normal warning packet.
  Future<bool> broadcastAlert(FeedAlert alert) {
    final text = alert.summaryText;
    final clipped = text.length > 180 ? '${text.substring(0, 177)}…' : text;
    return sendWarning(message: clipped, severity: 2, radiusKm: 25);
  }

  /// Encode and send a plain structured frame (voice chunk, ledger, missing
  /// person) with the same queue/receipt bookkeeping as a report.
  Future<bool> _emitRaw({
    required PacketType type,
    required Priority priority,
    required String text,
    required String logText,
    bool logEntry = true,
    bool trackReceipt = true,
  }) async {
    final seq = ++_sequenceId;
    final senderName = settings.username.isEmpty ? null : settings.username;
    final Uint8List frame;
    try {
      frame = encodeIbfs(IbfPacket(
        type: type,
        priority: priority,
        language: _senderLang,
        sequenceId: seq,
        text: text,
        senderName: senderName,
      ));
    } catch (_) {
      _statusMessage = 'Message too large for one frame';
      notifyListeners();
      return false;
    }

    int fanout;
    try {
      fanout = await transport.send(frame);
    } catch (e) {
      final reason = e is StateError ? e.message : e.toString();
      storeForward.enqueue(frame, sequenceId: seq);
      if (logEntry && logText.isNotEmpty) {
        _addLog(LogEntry(
          id: seq,
          timestamp: DateTime.now(),
          isSent: true,
          text: logText,
          langName: _senderLang.name,
          priority: priority,
          senderName: senderName,
          error: 'Not delivered — $reason\nQueued for automatic retry',
        ));
      }
      return false;
    }

    if (trackReceipt) _trackAck(seq, frame);
    if (logEntry && logText.isNotEmpty) {
      _addLog(LogEntry(
        id: seq,
        timestamp: DateTime.now(),
        isSent: true,
        text: logText,
        langName: _senderLang.name,
        priority: priority,
        senderName: senderName,
        awaitingAck: trackReceipt,
      ));
    }
    return fanout > 0;
  }

  /// Publish (or update) a relief camp and share it over the mesh.
  Future<bool> sendReliefUpdate({
    required String name,
    String? campId,
    double? lat,
    double? lon,
    Map<Need, int> needs = const <Need, int>{},
    Map<Need, int> supplies = const <Need, int>{},
    String? note,
  }) async {
    final campName = name.trim();
    if (campName.isEmpty) return false;
    final entry = ReliefEntry(
      id: campId ?? _newIncidentId(),
      name: campName.length > 28 ? campName.substring(0, 28) : campName,
      updatedAt: DateTime.now(),
      lat: lat,
      lon: lon,
      needs: needs,
      supplies: supplies,
      updatedBy: settings.username,
      note: (note ?? '').trim(),
    );
    _relief.upsert(entry);
    final short = entry.shortfall.entries
        .map((e) => '${e.value} ${e.key.label.toLowerCase()}')
        .join(', ');
    return _emitRaw(
      type: PacketType.reliefUpdate,
      priority: Priority.routine,
      text: entry.toWireJson(),
      logText: 'Camp ${entry.name}: '
          '${short.isEmpty ? 'supplies cover needs' : 'needs $short'}',
    );
  }

  /// Report a missing person and share the text record over the mesh.
  Future<bool> sendMissingPerson({
    String? id,
    required String name,
    int? age,
    String? note,
    String? lastSeen,
    String? photoPath,
  }) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return false;
    final person = MissingPerson(
      id: id ?? _newIncidentId(),
      name: trimmed.length > 28 ? trimmed.substring(0, 28) : trimmed,
      updatedAt: DateTime.now(),
      age: age,
      note: (note ?? '').trim(),
      lastSeen: (lastSeen ?? '').trim(),
      photoPath: photoPath,
      reportedBy: settings.username,
    );
    _missing.upsert(person);
    return _emitRaw(
      type: PacketType.missingPerson,
      priority: Priority.high,
      text: person.toWireJson(),
      logText: 'Missing: ${person.name}'
          '${person.age == null ? '' : ', ${person.age}'}'
          '${person.lastSeen.isEmpty ? '' : ' — last seen ${person.lastSeen}'}',
    );
  }

  /// Start a compressed voice note (fallback when transcription fails).
  Future<bool> startVoiceNote() async {
    if (_noteRecording) return false;
    if (!settings.canTransmit) {
      _statusMessage = 'Receiver-only mode: cannot record a voice note';
      notifyListeners();
      return false;
    }
    try {
      final dir = await getTemporaryDirectory();
      final path = '${dir.path}/itantra_note_'
          '${DateTime.now().millisecondsSinceEpoch}.m4a';
      final recorder = AudioRecorder();
      if (!await recorder.hasPermission()) {
        _statusMessage = 'Microphone permission denied';
        await recorder.dispose();
        notifyListeners();
        return false;
      }
      await recorder.start(
        const RecordConfig(
          encoder: AudioEncoder.aacLc,
          bitRate: 16000,
          sampleRate: 16000,
          numChannels: 1,
        ),
        path: path,
      );
      _noteRecorder = recorder;
      _notePath = path;
      _noteRecording = true;
      _statusMessage = 'Recording voice note — select the option again to send';
      notifyListeners();
      return true;
    } catch (e) {
      _statusMessage = 'Voice note failed: $e';
      notifyListeners();
      return false;
    }
  }

  /// Stop recording and transmit the clip as `voiceChunk` frames.
  Future<bool> stopAndSendVoiceNote() async {
    if (!_noteRecording) return false;
    _noteRecording = false;
    notifyListeners();

    String? path;
    try {
      path = await _noteRecorder?.stop();
    } catch (e) {
      debugPrint('[TransceiverController] voice note stop: $e');
    }
    await _noteRecorder?.dispose();
    _noteRecorder = null;

    final file = File(path ?? _notePath ?? '');
    _notePath = null;
    if (!await file.exists()) {
      _statusMessage = 'Voice note was not captured';
      notifyListeners();
      return false;
    }
    final bytes = await file.readAsBytes();
    if (bytes.isEmpty) {
      _statusMessage = 'Voice note was empty';
      notifyListeners();
      return false;
    }
    if (bytes.length > VoiceNoteChunk.maxNoteBytes) {
      _statusMessage = 'Voice note too long — keep it under 15 seconds';
      notifyListeners();
      return false;
    }

    final id = _rng
        .nextInt(0x10000)
        .toRadixString(16)
        .toUpperCase()
        .padLeft(4, '0');
    final chunks = <List<int>>[];
    for (var offset = 0;
        offset < bytes.length;
        offset += VoiceNoteChunk.maxChunkBytes) {
      final end =
          (offset + VoiceNoteChunk.maxChunkBytes).clamp(0, bytes.length);
      chunks.add(bytes.sublist(offset, end));
    }

    var sent = 0;
    for (var i = 0; i < chunks.length; i++) {
      final ok = await _emitRaw(
        type: PacketType.voiceChunk,
        priority: Priority.high,
        text: VoiceNoteChunk.encode(
          id: id,
          index: i,
          count: chunks.length,
          data: chunks[i],
        ),
        logText: '',
        logEntry: false,
        trackReceipt: false,
      );
      if (ok) sent++;
    }

    _addLog(LogEntry(
      id: ++_sequenceId,
      timestamp: DateTime.now(),
      isSent: true,
      text: '[Voice note · ${chunks.length} frames · '
          '${(bytes.length / 1024).toStringAsFixed(1)} KB]',
      langName: _senderLang.name,
      priority: Priority.high,
      senderName: settings.username.isEmpty ? null : settings.username,
      error: sent == chunks.length
          ? null
          : 'Only $sent of ${chunks.length} frames left the radio',
    ));
    _statusMessage = sent == chunks.length
        ? 'Voice note sent ($sent frames)'
        : 'Voice note partially sent ($sent/${chunks.length})';
    notifyListeners();
    return sent == chunks.length;
  }

  // ── Real-time Codec2 voice plumbing ──────────────────────────────

  /// Put one captured burst on the mesh. Batches are already ~60 ms of audio,
  /// so no extra pacing is needed.
  Future<void> _onCapturedVoiceFrame(LiveVoiceFrame frame) async {
    if (!_liveVoiceTx) return;
    if (frame.data.isEmpty) return;
    // Half duplex: opening the speaker while the microphone is live would feed
    // our own audio back into the mesh.
    await _emitRaw(
      type: PacketType.voiceFrame,
      priority: Priority.high,
      text: jsonEncode({'d': base64Encode(frame.data)}),
      logText: '',
      logEntry: false,
      trackReceipt: false,
    );
  }

  /// Hand a received burst to the speaker, opening playback on first use.
  void _onIncomingVoiceFrame(IbfPacket packet) {
    if (!settings.canReceive) return;
    if (_liveVoiceTx) return;
    // Do not talk over a voice note or a spoken translation.
    if (!_handsFree && _phase != TransceiverPhase.idle) return;

    Uint8List? data;
    try {
      final decoded = jsonDecode(packet.text);
      if (decoded is Map && decoded['d'] is String) {
        data = base64Decode(decoded['d'] as String);
      }
    } catch (_) {
      return;
    }
    if (data == null || data.isEmpty) return;

    unawaited(_playVoiceBurst(data));
  }

  Future<void> _playVoiceBurst(Uint8List data) async {
    if (!_liveVoice.isReceiving) {
      if (!await _liveVoice.startRx()) return;
    }
    await _liveVoice.push(data);
    // Close the speaker shortly after the last burst. Leaving an AudioTrack
    // open holds the audio route (and often the mic) for no reason.
    _liveVoiceRxTimer?.cancel();
    _liveVoiceRxTimer = Timer(const Duration(seconds: 2), () {
      unawaited(_liveVoice.stopRx());
    });
  }

  Future<void> _receiveVoiceNote(Uint8List bytes, IbfPacket packet) async {
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/itantra_recv_'
        '${DateTime.now().millisecondsSinceEpoch}.m4a');
    try {
      await file.writeAsBytes(bytes, flush: true);
    } catch (e) {
      debugPrint('[TransceiverController] voice note write: $e');
      return;
    }
    _addLog(LogEntry(
      id: packet.sequenceId,
      timestamp: DateTime.now(),
      isSent: false,
      text: '[Voice note · '
          '${(bytes.length / 1024).toStringAsFixed(1)} KB audio]',
      langName: packet.language.name,
      priority: packet.priority,
      senderName: packet.senderName,
    ));
    if (!settings.canReceive) return;
    // Half duplex: never play a note while our own transmission is running.
    if (!_handsFree && _phase != TransceiverPhase.idle) return;
    try {
      await _notePlayer.play(DeviceFileSource(file.path));
    } catch (e) {
      debugPrint('[TransceiverController] voice note playback: $e');
    }
  }

  @override
  void dispose() {
    settings.removeListener(_onSettingsChanged);
    _linkSubscription?.cancel();
    _silentSosSubscription?.cancel();
    _alarmTimer?.cancel();
    _ackTimer?.cancel();
    _ackTimer = null;
    _beaconTimer?.cancel();
    _beaconTimer = null;
    _incidents.removeListener(notifyListeners);
    _incidents.dispose();
    _relief.removeListener(notifyListeners);
    _relief.dispose();
    _missing.removeListener(notifyListeners);
    _missing.dispose();
    unawaited(_notePlayer.dispose());
    _noteRecorder?.dispose();
    _liveVoiceSub?.cancel();
    _liveVoiceRxTimer?.cancel();
    unawaited(_liveVoice.dispose());
    storeForward.dispose();
    transport.disconnect();
    stt.dispose();
    tts.dispose();
    translator.dispose();
    _timeSyncTimer?.cancel();
    _timeSyncTimer = null;
    _breadcrumbTimer?.cancel();
    _breadcrumbTimer = null;
    super.dispose();
  }
}

/// Result of encoding and handing one structured report to the radio.
class _EmitResult {
  const _EmitResult(this.sent, this.seq);

  /// Whether at least one peer received the frame.
  final bool sent;

  /// Sequence ID of the frame, used to match the delivery receipt.
  final int seq;
}

/// One frame that was handed to the radio and is awaiting a receipt.
class _PendingAck {
  _PendingAck(this.frame) : createdAt = DateTime.now(), lastAttempt = DateTime.now();

  final Uint8List frame;
  final DateTime createdAt;
  DateTime lastAttempt;

  /// How many times this frame has been put on the radio (initial send = 1).
  int attempts = 1;
}

/// Outcome of a cache cleanup, for the Settings snackbar.
class CacheClearReport {
  final int clipCount;
  final int clipBytes;
  final int logEntries;

  const CacheClearReport({
    required this.clipCount,
    required this.clipBytes,
    required this.logEntries,
  });

  String get prettySize {
    if (clipBytes < 1024) return '$clipBytes B';
    if (clipBytes < 1024 * 1024) {
      return '${(clipBytes / 1024).toStringAsFixed(1)} KB';
    }
    return '${(clipBytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}
