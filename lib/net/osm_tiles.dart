import 'dart:io';
import 'dart:math' as math;

import 'package:path_provider/path_provider.dart';

/// One slippy-map tile.
class OsmTileId {
  const OsmTileId(this.z, this.x, this.y);

  final int z;
  final int x;
  final int y;

  /// Path under `<documents>/offline_tiles`, identical to the layout
  /// `OfflineMapView` already reads.
  String get relativePath => '$z/$x/$y.png';

  @override
  String toString() => '$z/$x/$y';
}

/// Result of a download run.
class OsmDownloadResult {
  const OsmDownloadResult({
    required this.downloaded,
    required this.skipped,
    required this.failed,
    this.error,
  });

  final int downloaded;
  final int skipped;
  final int failed;
  final String? error;

  bool get ok => error == null && failed == 0;

  String get message {
    if (error != null) return error!;
    final parts = <String>[
      if (downloaded > 0) '$downloaded tile${downloaded == 1 ? '' : 's'} saved',
      if (skipped > 0) '$skipped already cached',
      if (failed > 0) '$failed failed',
    ];
    return parts.isEmpty ? 'Nothing to download' : parts.join(' · ');
  }
}

/// Downloads OpenStreetMap raster tiles into the same offline store the map
/// widget renders, so a responder can cache their area while connectivity
/// exists and then work with no network at all.
///
/// Usage policy: a descriptive `User-Agent`, sequential requests with at least
/// [minIntervalMs] between them, a hard [maxTiles] cap per run, and tiles are
/// cached on disk so a repeated request downloads nothing. This is deliberately
/// **not** a bulk scraper — downloading a district would violate the OSM tile
/// policy and is not needed for one incident position.
class OsmTileSource {
  OsmTileSource._();

  /// Standard OSM raster endpoint. Attribution is shown next to the map.
  static const String urlTemplate = 'https://tile.openstreetmap.org/{z}/{x}/{y}.png';

  /// Required by the OSM tile usage policy.
  static const String userAgent =
      'Sahara/0.4 (offline disaster-response app; +https://github.com/CVikasRaju/voice)';

  static const int minIntervalMs = 1100;
  static const int maxTiles = 9;

  static Uri tileUri(int z, int x, int y) => Uri.parse(urlTemplate
      .replaceAll('{z}', '$z')
      .replaceAll('{x}', '$x')
      .replaceAll('{y}', '$y'));

  /// Tiles covering a viewport centred on ([lat], [lon]).
  ///
  /// The maths mirrors [MercatorProjection] in `ui/widgets/offline_map.dart`;
  /// it is repeated here rather than importing a widget into the network layer.
  /// The result is capped at [maxTiles] by keeping the centre tiles first.
  static List<OsmTileId> viewportTiles({
    required double lat,
    required double lon,
    required int zoom,
    double widthPx = 360,
    double heightPx = 480,
    int maxTiles = maxTiles,
  }) {
    const tileSize = 256.0;
    final z = zoom.clamp(1, 19);
    final n = 1 << z;
    final scale = 1.0; // integer zoom: one world pixel is one screen pixel

    final centerX = (lon + 180.0) / 360.0 * n * tileSize;
    final sinLat = math.sin(lat.clamp(-85.0511, 85.0511) * math.pi / 180.0);
    final centerY =
        (0.5 - math.log((1 + sinLat) / (1 - sinLat)) / (4 * math.pi)) *
            n *
            tileSize;

    final firstX = ((centerX - widthPx / (2 * scale)) / tileSize).floor();
    final lastX = ((centerX + widthPx / (2 * scale)) / tileSize).floor();
    final firstY = ((centerY - heightPx / (2 * scale)) / tileSize).floor();
    final lastY = ((centerY + heightPx / (2 * scale)) / tileSize).floor();

    final centerTileX = (centerX / tileSize).floor();
    final centerTileY = (centerY / tileSize).floor();

    final tiles = <OsmTileId>[];
    for (var x = firstX; x <= lastX; x++) {
      for (var y = firstY; y <= lastY; y++) {
        if (y < 0 || y >= n) continue;
        final wrapped = ((x % n) + n) % n;
        tiles.add(OsmTileId(z, wrapped, y));
      }
    }

    // Centre-out ordering keeps the most useful tiles when the cap bites.
    tiles.sort((a, b) {
      final da = (a.x - centerTileX).abs() + (a.y - centerTileY).abs();
      final db = (b.x - centerTileX).abs() + (b.y - centerTileY).abs();
      return da.compareTo(db);
    });
    if (tiles.length > maxTiles) {
      return tiles.sublist(0, maxTiles);
    }
    return tiles;
  }

  /// Download the tiles around one position into [root] (defaults to
  /// `<documents>/offline_tiles`). Existing files are skipped, never re-fetched.
  static Future<OsmDownloadResult> downloadAround({
    required double lat,
    required double lon,
    int zoom = 14,
    double widthPx = 360,
    double heightPx = 480,
    int maxTiles = maxTiles,
    Directory? root,
    HttpClient? client,
    int minIntervalMs = minIntervalMs,
  }) async {
    Directory? target = root;
    if (target == null) {
      try {
        final docs = await getApplicationDocumentsDirectory();
        target = Directory('${docs.path}/offline_tiles');
      } catch (e) {
        return OsmDownloadResult(
          downloaded: 0,
          skipped: 0,
          failed: 0,
          error: 'No storage available: $e',
        );
      }
    }

    final tiles = viewportTiles(
      lat: lat,
      lon: lon,
      zoom: zoom,
      widthPx: widthPx,
      heightPx: heightPx,
      maxTiles: maxTiles,
    );

    var downloaded = 0, skipped = 0, failed = 0;
    String? error;
    final http = client ?? HttpClient();
    http.userAgent = userAgent;
    http.connectionTimeout = const Duration(seconds: 10);

    try {
      for (var i = 0; i < tiles.length; i++) {
        final tile = tiles[i];
        final file = File('${target.path}/${tile.relativePath}');
        if (await file.exists() && await file.length() > 0) {
          skipped++;
          continue;
        }
        if (i > 0) {
          await Future<void>.delayed(Duration(milliseconds: minIntervalMs));
        }
        try {
          final request = await http.getUrl(tileUri(tile.z, tile.x, tile.y));
          request.headers.set(HttpHeaders.acceptHeader, 'image/png,image/*');
          final response = await request.close();
          if (response.statusCode == 429) {
            error = 'OpenStreetMap rate limit reached — try again later';
            await response.drain<void>();
            break;
          }
          if (response.statusCode != 200) {
            failed++;
            await response.drain<void>();
            continue;
          }
          final bytes = await response.fold<List<int>>(
            <int>[],
            (buf, chunk) => buf..addAll(chunk),
          );
          // A redirect to an HTML error page is a failed tile, not an image.
          if (bytes.isEmpty || bytes.length > 400 * 1024) {
            failed++;
            continue;
          }
          await file.parent.create(recursive: true);
          await file.writeAsBytes(bytes, flush: true);
          downloaded++;
        } catch (_) {
          failed++;
        }
      }
    } finally {
      if (client == null) http.close(force: true);
    }

    return OsmDownloadResult(
      downloaded: downloaded,
      skipped: skipped,
      failed: failed,
      error: error,
    );
  }
}
