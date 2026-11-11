import 'dart:convert';
import 'dart:math' as math;

/// One GPS fix in a responder's breadcrumb trail.
class BreadcrumbPoint {
  const BreadcrumbPoint({
    required this.lat,
    required this.lon,
    required this.ts,
  });

  final double lat;
  final double lon;

  /// Epoch milliseconds on the mesh clock.
  final int ts;

  DateTime get time => DateTime.fromMillisecondsSinceEpoch(ts);

  Map<String, dynamic> toJson() => {'lat': lat, 'lon': lon, 'ts': ts};

  static BreadcrumbPoint? tryParse(dynamic raw) {
    if (raw is! List || raw.length < 2) return null;
    final lat = (raw[0] as num?)?.toDouble();
    final lon = (raw[1] as num?)?.toDouble();
    if (lat == null || lon == null) return null;
    if (lat < -90 || lat > 90 || lon < -180 || lon > 180) return null;
    final ts = raw.length > 2 ? (raw[2] as num?)?.toInt() : null;
    return BreadcrumbPoint(
      lat: lat,
      lon: lon,
      ts: ts ?? DateTime.now().millisecondsSinceEpoch,
    );
  }
}

/// A named trail (one sender or this device).
class BreadcrumbTrail {
  BreadcrumbTrail({this.maxPoints = 240});

  final int maxPoints;

  /// Trail key → points, oldest first.
  final Map<String, List<BreadcrumbPoint>> _trails = {};

  Map<String, List<BreadcrumbPoint>> get trails =>
      Map.unmodifiable(_trails);

  Iterable<List<BreadcrumbPoint>> get lines => _trails.values;

  int get pointCount =>
      _trails.values.fold(0, (sum, points) => sum + points.length);

  List<BreadcrumbPoint> forKey(String key) =>
      List.unmodifiable(_trails[key] ?? const <BreadcrumbPoint>[]);

  /// Add one local fix. Returns false when the device has not moved enough.
  bool addLocal(
    BreadcrumbPoint point, {
    double minMetres = 8,
    int minIntervalMs = 20000,
  }) {
    final key = localKey;
    final trail = _trails.putIfAbsent(key, () => <BreadcrumbPoint>[]);
    if (trail.isNotEmpty) {
      final last = trail.last;
      if (point.ts - last.ts < minIntervalMs &&
          _distanceMetres(last, point) < minMetres) {
        return false;
      }
      final same = last.lat == point.lat &&
          last.lon == point.lon &&
          last.ts == point.ts;
      if (same) return false;
    }
    trail.add(point);
    while (trail.length > maxPoints) {
      trail.removeAt(0);
    }
    return true;
  }

  /// Merge a batch heard from [sender]. Duplicate timestamps are ignored.
  int merge(String sender, List<BreadcrumbPoint> incoming) {
    if (incoming.isEmpty) return 0;
    final key = sender.trim().isEmpty ? 'unknown' : sender.trim();
    final trail = _trails.putIfAbsent(key, () => <BreadcrumbPoint>[]);
    final seen = trail.map((p) => p.ts).toSet();
    var added = 0;
    for (final point in incoming) {
      if (seen.add(point.ts)) {
        trail.add(point);
        added++;
      }
    }
    if (added == 0) return 0;
    trail.sort((a, b) => a.ts.compareTo(b.ts));
    while (trail.length > maxPoints) {
      trail.removeAt(0);
    }
    return added;
  }

  void clear() => _trails.clear();

  /// Key used for this device's own trail.
  static const String localKey = 'This phone';

  /// Wire form is deliberately tiny: `{"p":[[lat,lon,ts],...]}`.
  static String encodeBatch(List<BreadcrumbPoint> points) => jsonEncode({
        'p': [
          for (final p in points) [p.lat, p.lon, p.ts]
        ],
      });

  static List<BreadcrumbPoint> decodeBatch(String text) {
    if (!text.trimLeft().startsWith('{')) return const <BreadcrumbPoint>[];
    try {
      final j = jsonDecode(text);
      if (j is! Map<String, dynamic>) return const <BreadcrumbPoint>[];
      final raw = j['p'];
      if (raw is! List) return const <BreadcrumbPoint>[];
      final out = <BreadcrumbPoint>[];
      for (final item in raw.take(40)) {
        final point = BreadcrumbPoint.tryParse(item);
        if (point != null) out.add(point);
      }
      return out;
    } catch (_) {
      return const <BreadcrumbPoint>[];
    }
  }

  /// Haversine distance, used only to gate whether a new fix is worth sending.
  static double _distanceMetres(BreadcrumbPoint a, BreadcrumbPoint b) {
    const earth = 6371000.0;
    const rad = math.pi / 180.0;
    final dLat = (b.lat - a.lat) * rad;
    final dLon = (b.lon - a.lon) * rad;
    final lat = (a.lat + b.lat) / 2 * rad;
    final h = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(lat) *
            math.cos(lat) *
            math.sin(dLon / 2) *
            math.sin(dLon / 2);
    return 2 * earth * math.asin(math.min(1, math.sqrt(h)));
  }
}
