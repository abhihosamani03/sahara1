import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A missing-person record shared between responders.
///
/// The record travels as compact JSON in a `missingPerson` packet. The photo is
/// **local only**: a thumbnail is a few kilobytes, which would consume ~20
/// mesh frames and delay live SOS traffic. [photoPath] therefore points at a
/// file on the reporting phone, and a receiving phone shows the text record
/// with a clear "photo on reporter's device" marker rather than pretending it
/// has an image it never received.
class MissingPerson {
  const MissingPerson({
    required this.id,
    required this.name,
    required this.updatedAt,
    this.age,
    this.note = '',
    this.lastSeen = '',
    this.photoPath,
    this.reportedBy = '',
  });

  final String id;
  final String name;
  final DateTime updatedAt;
  final int? age;
  final String note;
  final String lastSeen;
  final String? photoPath;
  final String reportedBy;

  bool get hasPhoto => photoPath != null && photoPath!.isNotEmpty;

  /// Only render a thumbnail when the file really exists (a record relayed from
  /// another phone has a path that is meaningless here).
  File? get photoFile {
    if (!hasPhoto) return null;
    final file = File(photoPath!);
    return file.existsSync() ? file : null;
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'ts': updatedAt.millisecondsSinceEpoch,
        if (age != null) 'age': age,
        if (note.trim().isNotEmpty) 'note': note.trim(),
        if (lastSeen.trim().isNotEmpty) 'seen': lastSeen.trim(),
        if (hasPhoto) 'photo': photoPath,
        if (reportedBy.isNotEmpty) 'by': reportedBy,
      };

  /// Wire form deliberately omits the photo path: it is useless (and
  /// misleading) on another device.
  String toWireJson() {
    final j = toJson()..remove('photo');
    return jsonEncode(j);
  }

  factory MissingPerson.fromJson(Map<String, dynamic> j) => MissingPerson(
        id: (j['id'] as String?) ?? '',
        name: (j['name'] as String?) ?? '',
        updatedAt: DateTime.fromMillisecondsSinceEpoch(
          (j['ts'] as num?)?.toInt() ?? 0,
        ),
        age: (j['age'] as num?)?.toInt(),
        note: (j['note'] as String?) ?? '',
        lastSeen: (j['seen'] as String?) ?? '',
        photoPath: j['photo'] as String?,
        reportedBy: (j['by'] as String?) ?? '',
      );

  static MissingPerson? tryParse(String wire) {
    if (!wire.trimLeft().startsWith('{')) return null;
    try {
      final decoded = jsonDecode(wire);
      if (decoded is! Map<String, dynamic>) return null;
      final person = MissingPerson.fromJson(decoded);
      if (person.id.isEmpty || person.name.trim().isEmpty) return null;
      return person;
    } catch (_) {
      return null;
    }
  }
}

/// Offline registry with last-writer-wins merging, mirroring the incident board.
class MissingRegistry extends ChangeNotifier {
  static const String prefsKey = 'itantra_missing';
  static const int maxEntries = 50;

  final Map<String, MissingPerson> _byId = {};
  bool _disposed = false;

  List<MissingPerson> get entries {
    final list = _byId.values.toList()
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return List.unmodifiable(list);
  }

  bool get isEmpty => _byId.isEmpty;
  int get length => _byId.length;

  bool upsert(MissingPerson person) {
    if (_disposed || person.id.isEmpty || person.name.trim().isEmpty) {
      return false;
    }
    final existing = _byId[person.id];
    if (existing != null &&
        person.updatedAt.isBefore(existing.updatedAt)) {
      return false;
    }
    _byId[person.id] = person;
    while (_byId.length > maxEntries) {
      final oldest = _byId.values.reduce(
        (a, b) => a.updatedAt.isBefore(b.updatedAt) ? a : b,
      );
      _byId.remove(oldest.id);
    }
    notifyListeners();
    _persist();
    return true;
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

  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(prefsKey);
      if (raw == null || raw.isEmpty) return;
      final list = jsonDecode(raw);
      if (list is! List) return;
      for (final item in list) {
        if (item is Map<String, dynamic>) {
          final person = MissingPerson.fromJson(item);
          if (person.id.isNotEmpty) _byId[person.id] = person;
        }
      }
      if (!_disposed) notifyListeners();
    } catch (e) {
      debugPrint('[MissingRegistry] load failed: $e');
    }
  }

  Future<void> _persist() async {
    if (_disposed) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        prefsKey,
        jsonEncode(_byId.values.map((p) => p.toJson()).toList()),
      );
    } catch (e) {
      debugPrint('[MissingRegistry] persist failed: $e');
    }
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
