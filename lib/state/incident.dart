import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../ml/ibfs.dart';

/// ── Structured incident reporting ────────────────────────────────
///
/// Phase-1 Sahara only had free text (a transcript, an SOS note). That is
/// unusable for coordination: a command post cannot count "120 safe, 8 missing"
/// from prose, and it cannot sort by severity. The packet types added here use
/// the same iBFS frame — the JSON document simply travels in the existing text
/// field, so no wire-format change is needed and a 512-byte payload still fits
/// a full triage record (typically 120-220 bytes with GPS).

/// What a structured packet is.
enum IncidentKind { sos, status, checkIn, warning, assignment }

/// Resources a site needs. Sent as a compact list of names.
enum Need {
  water('Water'),
  food('Food'),
  medical('Medical'),
  shelter('Shelter'),
  rescue('Rescue');

  const Need(this.label);
  final String label;
}

/// Lifecycle of an incident.
enum IncidentStatus { open, assigned, resolved }

/// One report from the field, as received or as this device sent it.
class IncidentReport {
  const IncidentReport({
    required this.kind,
    required this.incidentId,
    required this.timestamp,
    this.sender,
    this.lat,
    this.lon,
    this.severity = 1,
    this.victims = 0,
    this.injured = 0,
    this.needs = const <Need>{},
    this.note = '',
    this.safe = true,
    this.peopleSafe = 0,
    this.peopleMissing = 0,
    this.status = IncidentStatus.open,
    this.assignedTeam,
    this.etaMinutes,
    this.radiusKm,
    this.expiresAt,
    this.battery,
    this.hops,
  });

  final IncidentKind kind;

  /// Stable ID for one incident, so an assignment updates the report it
  /// belongs to instead of creating a second one.
  final String incidentId;

  final DateTime timestamp;
  final String? sender;
  final double? lat;
  final double? lon;

  /// 0 low, 1 moderate, 2 high, 3 critical.
  final int severity;

  final int victims;
  final int injured;
  final Set<Need> needs;
  final String note;

  /// Check-in result: `true` means "I am safe".
  final bool safe;
  final int peopleSafe;
  final int peopleMissing;

  final IncidentStatus status;
  final String? assignedTeam;
  final int? etaMinutes;

  /// Radius of an early-warning area, in km (warnings only).
  final double? radiusKm;

  /// When a warning stops being valid.
  final DateTime? expiresAt;

  /// Sender's battery percentage at the time of the report, for triage.
  final int? battery;

  /// Mesh hop count, when the envelope carried one.
  final int? hops;

  bool get hasPosition => lat != null && lon != null;

  /// Key used by [IncidentBoard]. One incident ID = one row.
  String get key => incidentId;

  /// Colour bucket for the UI.
  String get severityLabel => switch (severity.clamp(0, 3)) {
        0 => 'Low',
        1 => 'Moderate',
        2 => 'High',
        _ => 'Critical',
      };

  /// The line shown in the log, spoken by TTS and shown on the alarm.
  ///
  /// Deliberately short: the structured fields are what a board displays, this
  /// is the human sentence.
  String get summaryLine {
    switch (kind) {
      case IncidentKind.sos:
        return note.trim().isEmpty ? 'SOS' : note.trim();
      case IncidentKind.status:
        final parts = <String>[];
        if (victims > 0) parts.add('$victims victims');
        if (injured > 0) parts.add('$injured injured');
        if (needs.isNotEmpty) {
          parts.add(needs.map((n) => n.label.toLowerCase()).join(', '));
        }
        final head = parts.isEmpty ? 'Status report' : 'Need help — ${parts.join(' · ')}';
        return note.trim().isEmpty ? head : '$head — ${note.trim()}';
      case IncidentKind.checkIn:
        if (safe) {
          final base = peopleSafe <= 1
              ? 'Safe'
              : 'Safe · $peopleSafe here';
          return peopleMissing > 0 ? '$base · $peopleMissing missing' : base;
        }
        return peopleMissing > 0
            ? 'NOT SAFE · $peopleMissing missing'
            : 'NOT SAFE';
      case IncidentKind.warning:
        return note.trim().isEmpty ? 'Warning' : note.trim();
      case IncidentKind.assignment:
        final team = assignedTeam ?? 'Responder';
        final eta = etaMinutes == null ? '' : ' · ETA $etaMinutes min';
        return '$team assigned$eta';
    }
  }

  /// Text worth translating: the sender's own note when there is one, the
  /// generated English summary otherwise.
  String get translatableText =>
      note.trim().isNotEmpty ? note.trim() : summaryLine;

  IncidentReport copyWith({
    double? lat,
    double? lon,
    String? sender,
    int? battery,
    int? hops,
    IncidentStatus? status,
    String? assignedTeam,
    int? etaMinutes,
  }) =>
      IncidentReport(
        kind: kind,
        incidentId: incidentId,
        timestamp: timestamp,
        sender: sender ?? this.sender,
        lat: lat ?? this.lat,
        lon: lon ?? this.lon,
        severity: severity,
        victims: victims,
        injured: injured,
        needs: needs,
        note: note,
        safe: safe,
        peopleSafe: peopleSafe,
        peopleMissing: peopleMissing,
        status: status ?? this.status,
        assignedTeam: assignedTeam ?? this.assignedTeam,
        etaMinutes: etaMinutes ?? this.etaMinutes,
        radiusKm: radiusKm,
        expiresAt: expiresAt,
        battery: battery ?? this.battery,
        hops: hops ?? this.hops,
      );

  /// Compact wire form. Short keys keep a full report well under 250 bytes.
  Map<String, dynamic> toJson() => {
        'k': kind.name,
        'id': incidentId,
        'ts': timestamp.millisecondsSinceEpoch,
        if (sender != null && sender!.isNotEmpty) 'from': sender,
        if (lat != null) 'lat': lat,
        if (lon != null) 'lon': lon,
        'sev': severity,
        if (victims > 0) 'vic': victims,
        if (injured > 0) 'inj': injured,
        if (needs.isNotEmpty) 'need': needs.map((n) => n.name).toList(),
        if (note.trim().isNotEmpty) 'note': note.trim(),
        if (kind == IncidentKind.checkIn) 'safe': safe,
        if (peopleSafe > 0) 'ps': peopleSafe,
        if (peopleMissing > 0) 'pm': peopleMissing,
        if (status != IncidentStatus.open) 'st': status.name,
        if (assignedTeam != null) 'team': assignedTeam,
        if (etaMinutes != null) 'eta': etaMinutes,
        if (radiusKm != null) 'r': radiusKm,
        if (expiresAt != null) 'exp': expiresAt!.millisecondsSinceEpoch,
        if (battery != null) 'bat': battery,
      };

  String toWireJson() => jsonEncode(toJson());

  factory IncidentReport.fromJson(Map<String, dynamic> j) {
    return IncidentReport(
      kind: _kindFrom(j['k']),
      incidentId: (j['id'] as String?) ?? '',
      timestamp: DateTime.fromMillisecondsSinceEpoch(_int(j['ts']) ??
          DateTime.now().millisecondsSinceEpoch),
      sender: j['from'] as String?,
      lat: _double(j['lat']),
      lon: _double(j['lon']),
      severity: _int(j['sev'])?.clamp(0, 3) ?? 1,
      victims: _int(j['vic']) ?? 0,
      injured: _int(j['inj']) ?? 0,
      needs: _needsFrom(j['need']),
      note: (j['note'] as String?) ?? '',
      safe: (j['safe'] as bool?) ?? true,
      peopleSafe: _int(j['ps']) ?? 0,
      peopleMissing: _int(j['pm']) ?? 0,
      status: _statusFrom(j['st']),
      assignedTeam: j['team'] as String?,
      etaMinutes: _int(j['eta']),
      radiusKm: _double(j['r']),
      expiresAt: _int(j['exp']) == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(_int(j['exp'])!),
      battery: _int(j['bat']),
      hops: _int(j['hop']),
    );
  }

  /// Build a report from a decoded packet, or `null` for a normal voice frame.
  ///
  /// A malformed JSON body is not dropped: the frame's CRC already proved it
  /// arrived intact, so the raw text is kept as a note. On a distress channel a
  /// readable sentence beats a discarded packet.
  static IncidentReport? tryFromPacket(IbfPacket p) {
    final kind = switch (p.type) {
      PacketType.silentSos => IncidentKind.sos,
      PacketType.statusReport => IncidentKind.status,
      PacketType.checkIn => IncidentKind.checkIn,
      PacketType.alert => IncidentKind.warning,
      PacketType.assignment => IncidentKind.assignment,
      _ => null,
    };
    if (kind == null) return null;

    if (p.text.trimLeft().startsWith('{')) {
      try {
        final decoded = jsonDecode(p.text);
        if (decoded is Map<String, dynamic>) {
          final report = IncidentReport.fromJson(decoded);
          // Position and identity from the header win: they are not forgeable
          // by a mistyped body, and an old peer may send neither in JSON.
          return report.copyWith(
            lat: p.latitude ?? report.lat,
            lon: p.longitude ?? report.lon,
            sender: p.senderName ?? report.sender,
          );
        }
      } catch (_) {
        // Fall through to the plain-text form below.
      }
    }

    return IncidentReport(
      kind: kind,
      incidentId: 'seq-${p.sequenceId}',
      timestamp: DateTime.now(),
      sender: p.senderName,
      lat: p.latitude,
      lon: p.longitude,
      severity: p.priority == Priority.emergency ? 3 : 1,
      note: p.text.trim(),
      safe: false,
      peopleMissing: 0,
    );
  }

  static IncidentKind _kindFrom(Object? raw) {
    for (final k in IncidentKind.values) {
      if (k.name == raw) return k;
    }
    return IncidentKind.status;
  }

  static IncidentStatus _statusFrom(Object? raw) {
    for (final s in IncidentStatus.values) {
      if (s.name == raw) return s;
    }
    return IncidentStatus.open;
  }

  static Set<Need> _needsFrom(Object? raw) {
    if (raw is! List) return const <Need>{};
    final out = <Need>{};
    for (final item in raw) {
      for (final n in Need.values) {
        if (n.name == item) out.add(n);
      }
    }
    return out;
  }

  static int? _int(Object? v) => v is num ? v.toInt() : null;
  static double? _double(Object? v) => v is num ? v.toDouble() : null;
}

/// Aggregate counters for the board header.
class IncidentCounts {
  const IncidentCounts({
    required this.sos,
    required this.warnings,
    required this.safe,
    required this.missing,
    required this.injured,
    required this.open,
  });

  final int sos;
  final int warnings;
  final int safe;
  final int missing;
  final int injured;
  final int open;

  bool get isEmpty =>
      sos == 0 && warnings == 0 && safe == 0 && missing == 0 && open == 0;
}

/// Offline, single-device aggregation of every report heard over the mesh.
///
/// No server, no database: the board is the union of the reports this phone has
/// received, which is exactly what a responder holding one phone needs. It is
/// persisted so the picture survives a restart when the network does not come
/// back for days.
class IncidentBoard extends ChangeNotifier {
  static const _prefsKey = 'itantra_incidents';
  static const int maxReports = 200;

  final Map<String, IncidentReport> _byKey = {};

  /// Set when the controller is torn down while a load is still in flight.
  bool _disposed = false;

  /// Reports, most urgent and most recent first.
  List<IncidentReport> get reports {
    final list = _byKey.values.toList()
      ..sort((a, b) {
        final bySeverity = b.severity.compareTo(a.severity);
        if (bySeverity != 0) return bySeverity;
        final byTime = b.timestamp.compareTo(a.timestamp);
        if (byTime != 0) return byTime;
        return a.incidentId.compareTo(b.incidentId);
      });
    return List.unmodifiable(list);
  }

  List<IncidentReport> byKind(IncidentKind kind) =>
      reports.where((r) => r.kind == kind).toList();

  IncidentReport? byId(String incidentId) => _byKey[incidentId];

  bool get isEmpty => _byKey.isEmpty;

  int get length => _byKey.length;

  IncidentCounts get counts {
    var sos = 0, warnings = 0, safe = 0, missing = 0, injured = 0, open = 0;
    for (final r in _byKey.values) {
      switch (r.kind) {
        case IncidentKind.sos:
          if (r.status != IncidentStatus.resolved) sos++;
        case IncidentKind.warning:
          warnings++;
        case IncidentKind.checkIn:
          if (r.safe) {
            safe += r.peopleSafe <= 0 ? 1 : r.peopleSafe;
          } else {
            missing += r.peopleMissing;
          }
        case IncidentKind.status:
          injured += r.injured;
          if (r.status != IncidentStatus.resolved) open++;
        case IncidentKind.assignment:
          break;
      }
    }
    return IncidentCounts(
      sos: sos,
      warnings: warnings,
      safe: safe,
      missing: missing,
      injured: injured,
      open: open,
    );
  }

  /// Total number of sites asking for each resource.
  Map<Need, int> get needTotals {
    final totals = <Need, int>{};
    for (final r in _byKey.values) {
      if (r.status == IncidentStatus.resolved) continue;
      for (final n in r.needs) {
        totals[n] = (totals[n] ?? 0) + 1;
      }
    }
    return totals;
  }

  /// Insert or update one report. Older copies are ignored so a replayed frame
  /// cannot roll an incident back from "assigned" to "open".
  void upsert(IncidentReport report) {
    if (_disposed) return;
    if (report.incidentId.isEmpty) return;
    // An assignment is a state change for an existing incident, not a new row.
    // Upserting it under the same key would replace the SOS it refers to.
    if (report.kind == IncidentKind.assignment) {
      applyAssignment(
        incidentId: report.incidentId,
        team: report.assignedTeam ?? 'Responder',
        etaMinutes: report.etaMinutes ?? 0,
      );
      return;
    }
    final existing = _byKey[report.key];
    if (existing != null && existing.timestamp.isAfter(report.timestamp)) {
      // Still let an assignment through: it is newer state with an older clock.
      if (report.kind != IncidentKind.assignment) return;
    }
    _byKey[report.key] = report;
    _trim();
    notifyListeners();
    unawaitedPersist();
  }

  /// Apply a responder assignment to the incident it names.
  bool applyAssignment({
    required String incidentId,
    required String team,
    required int etaMinutes,
  }) {
    if (_disposed) return false;
    final existing = _byKey[incidentId];
    if (existing == null) return false;
    _byKey[incidentId] = existing.copyWith(
      status: IncidentStatus.assigned,
      assignedTeam: team,
      etaMinutes: etaMinutes,
    );
    notifyListeners();
    unawaitedPersist();
    return true;
  }

  /// Mark an incident resolved (user action on the board).
  bool resolve(String incidentId) {
    if (_disposed) return false;
    final existing = _byKey[incidentId];
    if (existing == null) return false;
    _byKey[incidentId] = existing.copyWith(status: IncidentStatus.resolved);
    notifyListeners();
    unawaitedPersist();
    return true;
  }

  void clear() {
    if (_disposed || _byKey.isEmpty) return;
    _byKey.clear();
    notifyListeners();
    unawaitedPersist();
  }

  void _trim() {
    if (_byKey.length <= maxReports) return;
    final oldest = _byKey.values.toList()
      ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
    for (var i = 0; i < oldest.length - maxReports; i++) {
      _byKey.remove(oldest[i].key);
    }
  }

  /// Restore the board. Safe to call before `runApp`.
  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefsKey);
      if (raw == null || raw.isEmpty) return;
      final list = jsonDecode(raw);
      if (list is! List) return;
      for (final item in list) {
        if (item is Map<String, dynamic>) {
          final report = IncidentReport.fromJson(item);
          if (report.incidentId.isNotEmpty) _byKey[report.key] = report;
        }
      }
      if (_disposed) return;
      notifyListeners();
    } catch (e) {
      debugPrint('[IncidentBoard] load failed: $e');
    }
  }

  /// Not awaited by callers: a board update must never block the receive path.
  void unawaitedPersist() {
    _persist();
  }

  Future<void> _persist() async {
    if (_disposed) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final json = _byKey.values.map((r) => r.toJson()).toList();
      await prefs.setString(_prefsKey, jsonEncode(json));
    } catch (e) {
      debugPrint('[IncidentBoard] persist failed: $e');
    }
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
