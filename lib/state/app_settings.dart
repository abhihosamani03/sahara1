import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../ml/ibfs.dart' show kMaxSenderNameChars;

/// How the microphone is driven.
enum OperationMode {
  /// Classic half-duplex push-to-talk: hold (or tap) to talk, release to send.
  walkieTalkie,

  /// Hands-free: the mic stays open and Silero VAD finalises a sentence after
  /// a period of silence, then sends it with no button press.
  phone,
}

/// What this device is allowed to do.
///
/// The competition evaluation asks for two phones to be set up as a minimal
/// sender/receiver pair, which is what [sttOnly] and [ttsOnly] are for; a
/// real deployment uses [transceiver].
enum AppRole {
  /// Bidirectional: transmit and receive.
  transceiver,

  /// Sender only — microphone capture, transcribing, transmission benchmarks.
  /// Incoming audio playback is disabled.
  sttOnly,

  /// Receiver only — mesh reception, translation, queueing, loud synthesis.
  /// Microphone capture is disabled.
  ttsOnly,
}

/// User preferences, persisted with `shared_preferences`.
///
/// A single instance is created in `main()` and shared by the controller and
/// the Settings screen, so there is exactly one source of truth for each
/// preference — the pre-Settings build had the GPS toggle living in the
/// controller only, which is how preferences drift apart.
class AppSettings extends ChangeNotifier {
  static const _kUsername = 'set.username';
  static const _kSpeechRate = 'set.speechRate';
  static const _kSilentSos = 'set.silentSos';
  static const _kTranslation = 'set.translation';
  static const _kBloodGroup = 'set.bloodGroup';
  static const _kConditions = 'set.conditions';
  static const _kContacts = 'set.emergencyContacts';
  static const _kOperationMode = 'set.operationMode';
  static const _kRole = 'set.role';
  static const _kGpsEnabled = 'set.gpsEnabled';
  static const _kAlertFeeds = 'set.alertFeeds';
  static const _kRelayMode = 'set.relayMode';
  static const _kStartOnBoot = 'set.startOnBoot';
  static const _kBreadcrumbs = 'set.breadcrumbsEnriched';
  static const _kLiveVoice = 'set.liveVoice';

  /// Slowest permitted speech rate.
  static const double minSpeechRate = 0.5;

  /// Fastest permitted speech rate.
  static const double maxSpeechRate = 1.5;

  String _username = '';
  double _speechRate = 1.0;
  bool _silentSosEnabled = true;
  bool _translationEnabled = true;
  String _bloodGroup = '';
  String _conditions = '';
  String _emergencyContacts = '';
  OperationMode _operationMode = OperationMode.walkieTalkie;
  AppRole _role = AppRole.transceiver;
  bool _gpsEnabled = true;
  List<String> _alertFeeds = const [];
  bool _relayMode = false;
  bool _startOnBoot = false;
  bool _breadcrumbsEnabled = false;
  bool _liveVoice = false;

  /// RSS/Atom URLs polled when the user asks for early-warning alerts.
  List<String> get alertFeeds => List.unmodifiable(_alertFeeds);

  /// Caller-supplied name, transmitted in every packet (max 8 characters).
  String get username => _username;

  /// TTS playback speed multiplier, applied to both the neural and platform
  /// voices.
  double get speechRate => _speechRate;

  /// Whether long-pressing a volume key fires an SOS.
  bool get silentSosEnabled => _silentSosEnabled;

  /// Whether incoming packets in another language are translated before being
  /// spoken.
  bool get translationEnabled => _translationEnabled;

  /// Blood group, shown on an SOS card so rescuers do not have to ask.
  String get bloodGroup => _bloodGroup;

  /// Pre-existing medical conditions, shown on an SOS card.
  String get conditions => _conditions;

  /// Emergency contact IDs/numbers, shown on an SOS card.
  String get emergencyContacts => _emergencyContacts;

  /// Push-to-talk or hands-free.
  OperationMode get operationMode => _operationMode;

  /// Transceiver, sender-only or receiver-only.
  AppRole get role => _role;

  /// Whether outgoing packets are GPS-stamped.
  bool get gpsEnabled => _gpsEnabled;

  /// Relay-only mode: this phone carries traffic for others and does no
  /// recognition or synthesis of its own.
  bool get relayMode => _relayMode;

  /// Start emergency standby (and the mesh) after a reboot.
  bool get startOnBoot => _startOnBoot;

  /// Share this phone's GPS breadcrumb trail with the mesh.
  bool get breadcrumbsEnabled => _breadcrumbsEnabled;

  /// Send real-time Codec2 audio on PTT instead of offline speech text.
  bool get liveVoiceEnabled => _liveVoice;

  bool get isHandsFree => _operationMode == OperationMode.phone;
  bool get canTransmit => !_relayMode && _role != AppRole.ttsOnly;
  bool get canReceive => !_relayMode && _role != AppRole.sttOnly;

  /// Whether any medical telemetry has been filled in.
  bool get hasMedicalInfo =>
      _bloodGroup.trim().isNotEmpty ||
      _conditions.trim().isNotEmpty ||
      _emergencyContacts.trim().isNotEmpty;

  /// One-line summary for the SOS notification, or `null` when unset.
  String? get medicalSummary {
    final parts = <String>[];
    if (_bloodGroup.trim().isNotEmpty) {
      parts.add('Blood ${_bloodGroup.trim()}');
    }
    if (_conditions.trim().isNotEmpty) parts.add(_conditions.trim());
    if (_emergencyContacts.trim().isNotEmpty) {
      parts.add('Contact ${_emergencyContacts.trim()}');
    }
    return parts.isEmpty ? null : parts.join(' · ');
  }

  /// Load every preference. Safe to call before `runApp`.
  Future<void> load() async {
    try {
      final p = await SharedPreferences.getInstance();
      _username = _sanitiseName(p.getString(_kUsername) ?? '');
      _speechRate = _clampRate(p.getDouble(_kSpeechRate) ?? 1.0);
      _silentSosEnabled = p.getBool(_kSilentSos) ?? true;
      _translationEnabled = p.getBool(_kTranslation) ?? true;
      _bloodGroup = p.getString(_kBloodGroup) ?? '';
      _conditions = p.getString(_kConditions) ?? '';
      _emergencyContacts = p.getString(_kContacts) ?? '';
      _operationMode = _modeFromName(p.getString(_kOperationMode));
      _role = _roleFromName(p.getString(_kRole));
      _gpsEnabled = p.getBool(_kGpsEnabled) ?? true;
      _alertFeeds = _splitFeeds(p.getString(_kAlertFeeds));
      _relayMode = p.getBool(_kRelayMode) ?? false;
      _startOnBoot = p.getBool(_kStartOnBoot) ?? false;
      _breadcrumbsEnabled = p.getBool(_kBreadcrumbs) ?? false;
      _liveVoice = p.getBool(_kLiveVoice) ?? false;
    } catch (e) {
      debugPrint('[AppSettings] load failed: $e');
    }
    notifyListeners();
  }

  set username(String v) {
    final next = _sanitiseName(v);
    if (next == _username) return;
    _username = next;
    _persist(_kUsername, next);
  }

  set speechRate(double v) {
    final next = _clampRate(v);
    if (next == _speechRate) return;
    _speechRate = next;
    _persist(_kSpeechRate, next);
  }

  set silentSosEnabled(bool v) {
    if (v == _silentSosEnabled) return;
    _silentSosEnabled = v;
    _persist(_kSilentSos, v);
  }

  set translationEnabled(bool v) {
    if (v == _translationEnabled) return;
    _translationEnabled = v;
    _persist(_kTranslation, v);
  }

  set bloodGroup(String v) {
    if (v == _bloodGroup) return;
    _bloodGroup = v;
    _persist(_kBloodGroup, v);
  }

  set conditions(String v) {
    if (v == _conditions) return;
    _conditions = v;
    _persist(_kConditions, v);
  }

  set emergencyContacts(String v) {
    if (v == _emergencyContacts) return;
    _emergencyContacts = v;
    _persist(_kContacts, v);
  }

  set operationMode(OperationMode v) {
    if (v == _operationMode) return;
    _operationMode = v;
    _persist(_kOperationMode, v.name);
  }

  set role(AppRole v) {
    if (v == _role) return;
    _role = v;
    _persist(_kRole, v.name);
  }

  set gpsEnabled(bool v) {
    if (v == _gpsEnabled) return;
    _gpsEnabled = v;
    _persist(_kGpsEnabled, v);
  }

  set relayMode(bool v) {
    if (v == _relayMode) return;
    _relayMode = v;
    _persist(_kRelayMode, v);
  }

  set startOnBoot(bool v) {
    if (v == _startOnBoot) return;
    _startOnBoot = v;
    _persist(_kStartOnBoot, v);
  }

  set breadcrumbsEnabled(bool v) {
    if (v == _breadcrumbsEnabled) return;
    _breadcrumbsEnabled = v;
    _persist(_kBreadcrumbs, v);
  }

  set liveVoiceEnabled(bool v) {
    if (v == _liveVoice) return;
    _liveVoice = v;
    _persist(_kLiveVoice, v);
  }

  set alertFeeds(List<String> urls) {
    final cleaned = urls
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList(growable: false);
    if (listEquals(cleaned, _alertFeeds)) return;
    _alertFeeds = cleaned;
    _persist(_kAlertFeeds, cleaned.join('\n'));
  }

  static List<String> _splitFeeds(String? raw) {
    if (raw == null || raw.trim().isEmpty) return const [];
    return raw
        .split('\n')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList(growable: false);
  }

  /// Reset everything the "clear caches" action should not touch but a user
  /// may want to wipe: the medical block. Kept explicit rather than implied.
  void clearMedicalInfo() {
    bloodGroup = '';
    conditions = '';
    emergencyContacts = '';
  }

  /// Trim, drop control characters and clamp to the wire limit.
  ///
  /// Clamping here (not only in the codec) means the UI cannot show a name
  /// that will not be transmitted.
  static String _sanitiseName(String raw) {
    final cleaned = raw
        .replaceAll(RegExp(r'[\u0000-\u001F\u007F]'), '')
        .trim();
    final runes = cleaned.runes.toList();
    if (runes.length <= kMaxSenderNameChars) return cleaned;
    return String.fromCharCodes(runes.sublist(0, kMaxSenderNameChars));
  }

  static double _clampRate(double v) {
    if (v.isNaN) return 1.0;
    return v.clamp(minSpeechRate, maxSpeechRate).toDouble();
  }

  static OperationMode _modeFromName(String? name) {
    for (final m in OperationMode.values) {
      if (m.name == name) return m;
    }
    return OperationMode.walkieTalkie;
  }

  static AppRole _roleFromName(String? name) {
    for (final r in AppRole.values) {
      if (r.name == name) return r;
    }
    return AppRole.transceiver;
  }

  void _persist(String key, Object value) {
    notifyListeners();
    // Intentionally not awaited: a preference write must never block the UI,
    // and SharedPreferences already applies the value in memory immediately.
    SharedPreferences.getInstance().then((p) {
      if (value is String) {
        p.setString(key, value);
      } else if (value is double) {
        p.setDouble(key, value);
      } else if (value is bool) {
        p.setBool(key, value);
      }
    }).catchError((Object e) {
      debugPrint('[AppSettings] persist $key failed: $e');
    });
  }
}
