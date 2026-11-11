import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'incident.dart' show Need;

/// One relief camp (or shelter) as seen by this phone.
///
/// Needs and supplies are counts per resource, so a camp post can publish
/// "need 200 water, have 40" in a single 512-byte packet and every responder
/// holding a phone sees the shortfall without a server.
class ReliefEntry {
  const ReliefEntry({
    required this.id,
    required this.name,
    required this.updatedAt,
    this.lat,
    this.lon,
    this.needs = const <Need, int>{},
    this.supplies = const <Need, int>{},
    this.updatedBy = '',
    this.note = '',
  });

  final String id;
  final String name;
  final DateTime updatedAt;
  final double? lat;
  final double? lon;
  final Map<Need, int> needs;
  final Map<Need, int> supplies;
  final String updatedBy;
  final String note;

  bool get hasPosition => lat != null && lon != null;

  /// Positive when the camp has a surplus, negative when it is short.
  int balance(Need need) => (supplies[need] ?? 0) - (needs[need] ?? 0);

  bool get hasShortfall => needs.keys.any((n) => balance(n) < 0);

  /// Resources still needed, largest shortfall first.
  Map<Need, int> get shortfall {
    final out = <Need, int>{};
    for (final need in needs.keys) {
      final missing = -balance(need);
      if (missing > 0) out[need] = missing;
    }
    final sorted = out.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return {for (final e in sorted) e.key: e.value};
  }

  ReliefEntry copyWith({
    String? name,
    DateTime? updatedAt,
    double? lat,
    double? lon,
    Map<Need, int>? needs,
    Map<Need, int>? supplies,
    String? updatedBy,
    String? note,
  }) =>
      ReliefEntry(
        id: id,
        name: name ?? this.name,
        updatedAt: updatedAt ?? this.updatedAt,
        lat: lat ?? this.lat,
        lon: lon ?? this.lon,
        needs: needs ?? this.needs,
        supplies: supplies ?? this.supplies,
        updatedBy: updatedBy ?? this.updatedBy,
        note: note ?? this.note,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'ts': updatedAt.millisecondsSinceEpoch,
        if (lat != null) 'lat': lat,
        if (lon != null) 'lon': lon,
        if (needs.isNotEmpty)
          'need': {for (final e in needs.entries) e.key.name: e.value},
        if (supplies.isNotEmpty)
          'sup': {for (final e in supplies.entries) e.key.name: e.value},
        if (updatedBy.isNotEmpty) 'by': updatedBy,
        if (note.trim().isNotEmpty) 'note': note.trim(),
      };

  String toWireJson() => jsonEncode(toJson());

  factory ReliefEntry.fromJson(Map<String, dynamic> j) => ReliefEntry(
        id: (j['id'] as String?) ?? '',
        name: (j['name'] as String?) ?? '',
        updatedAt: DateTime.fromMillisecondsSinceEpoch(
          (j['ts'] as num?)?.toInt() ?? 0,
        ),
        lat: (j['lat'] as num?)?.toDouble(),
        lon: (j['lon'] as num?)?.toDouble(),
        needs: _counts(j['need']),
        supplies: _counts(j['sup']),
        updatedBy: (j['by'] as String?) ?? '',
        note: (j['note'] as String?) ?? '',
      );

  static ReliefEntry? tryParse(String wire) {
    if (!wire.trimLeft().startsWith('{')) return null;
    try {
      final decoded = jsonDecode(wire);
      if (decoded is! Map<String, dynamic>) return null;
      final entry = ReliefEntry.fromJson(decoded);
      if (entry.id.isEmpty || entry.name.trim().isEmpty) return null;
      return entry;
    } catch (_) {
      return null;
    }
  }

  static Map<Need, int> _counts(Object? raw) {
    if (raw is! Map) return const <Need, int>{};
    final out = <Need, int>{};
    raw.forEach((key, value) {
      for (final need in Need.values) {
        if (need.name == key && value is num) {
          out[need] = value.toInt().clamp(0, 99999);
        }
      }
    });
    return out;
  }
}

/// Converging, offline ledger of camps.
///
/// Last-writer-wins per camp, keyed by timestamp; equal timestamps are broken
/// by [ReliefEntry.updatedBy] so two phones applying the same two updates in
/// opposite order still end up with the same state.
class ReliefLedger extends ChangeNotifier {
  static const String prefsKey = 'itantra_relief';
  static const int maxEntries = 100;

  final Map<String, ReliefEntry> _byId = {};
  bool _disposed = false;
  bool _loaded = false;

  List<ReliefEntry> get entries {
    final list = _byId.values.toList()
      ..sort((a, b) {
        final short = (b.hasShortfall ? 1 : 0).compareTo(a.hasShortfall ? 1 : 0);
        if (short != 0) return short;
        return b.updatedAt.compareTo(a.updatedAt);
      });
    return List.unmodifiable(list);
  }

  bool get isEmpty => _byId.isEmpty;
  int get length => _byId.length;
  bool get isLoaded => _loaded;

  ReliefEntry? byId(String id) => _byId[id];

  /// Total shortfall across every camp, for a depot deciding what to load.
  Map<Need, int> get shortfallTotals {
    final totals = <Need, int>{};
    for (final entry in _byId.values) {
      entry.shortfall.forEach((need, count) {
        totals[need] = (totals[need] ?? 0) + count;
      });
    }
    return totals;
  }

  /// Merge one entry. Returns `true` when it changed the ledger.
  bool upsert(ReliefEntry entry) {
    if (_disposed || entry.id.isEmpty) return false;
    final existing = _byId[entry.id];
    if (existing != null) {
      final byTime = entry.updatedAt.compareTo(existing.updatedAt);
      if (byTime < 0) return false;
      if (byTime == 0 && entry.updatedBy.compareTo(existing.updatedBy) <= 0) {
        return false;
      }
    }
    _byId[entry.id] = entry;
    _trim();
    notifyListeners();
    _persist();
    return true;
  }

  /// Apply a stock/need count change to an existing camp.
  bool adjust(
    String id, {
    Need? need,
    int? needCount,
    int? supplyCount,
    String updatedBy = '',
  }) {
    final existing = _byId[id];
    if (existing == null) return false;
    final needs = Map<Need, int>.of(existing.needs);
    final supplies = Map<Need, int>.of(existing.supplies);
    if (need != null) {
      if (needCount != null) {
        if (needCount <= 0) {
          needs.remove(need);
        } else {
          needs[need] = needCount;
        }
      }
      if (supplyCount != null) {
        if (supplyCount <= 0) {
          supplies.remove(need);
        } else {
          supplies[need] = supplyCount;
        }
      }
    }
    return upsert(existing.copyWith(
      needs: needs,
      supplies: supplies,
      updatedAt: DateTime.now(),
      updatedBy: updatedBy,
    ));
  }

  bool remove(String id) {
    if (_disposed || _byId.remove(id) == null) return false;
    notifyListeners();
    _persist();
    return true;
  }

  void clear() {
    if (_disposed || _byId.isEmpty) return;
    _byId.clear();
    notifyListeners();
    _persist();
  }

  void _trim() {
    if (_byId.length <= maxEntries) return;
    final oldest = _byId.values.toList()
      ..sort((a, b) => a.updatedAt.compareTo(b.updatedAt));
    for (var i = 0; i < oldest.length - maxEntries; i++) {
      _byId.remove(oldest[i].id);
    }
  }

  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(prefsKey);
      if (raw != null && raw.isNotEmpty) {
        final list = jsonDecode(raw);
        if (list is List) {
          for (final item in list) {
            if (item is Map<String, dynamic>) {
              final entry = ReliefEntry.fromJson(item);
              if (entry.id.isNotEmpty) _byId[entry.id] = entry;
            }
          }
        }
      }
    } catch (e) {
      debugPrint('[ReliefLedger] load failed: $e');
    }
    _loaded = true;
    if (!_disposed) notifyListeners();
  }

  Future<void> _persist() async {
    if (_disposed) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        prefsKey,
        jsonEncode(_byId.values.map((e) => e.toJson()).toList()),
      );
    } catch (e) {
      debugPrint('[ReliefLedger] persist failed: $e');
    }
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
