import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

/// Result of importing one `.mbtiles` archive.
class MbtilesImportResult {
  const MbtilesImportResult({
    required this.imported,
    required this.skipped,
    required this.zooms,
    required this.total,
    this.error,
    this.cancelled = false,
  });

  final int imported;
  final int skipped;
  final int total;
  final List<int> zooms;
  final String? error;
  final bool cancelled;

  bool get ok => error == null;

  String get message {
    if (error != null) return error!;
    if (imported == 0 && skipped > 0) {
      return 'All $skipped tiles were already installed';
    }
    final zoomText = zooms.isEmpty ? '' : ' · z${zooms.first}–${zooms.last}';
    return '$imported tile${imported == 1 ? '' : 's'} imported'
        '${skipped > 0 ? ' · $skipped already present' : ''}$zoomText';
  }
}

/// Imports an MBTiles region bundle into `<documents>/offline_tiles`.
///
/// MBTiles is SQLite with a `tiles` table. Rows are TMS (row 0 is the south
/// edge), while the map widget reads the universal XYZ layout (row 0 is the
/// north edge), so the row is flipped on the way out:
/// `y = (1 << zoom) - 1 - tile_row`.
///
/// The archive is read in pages rather than one `SELECT *`, because a district
/// bundle can contain tens of thousands of tiles and loading them all would
/// double memory use on the phones this is meant for.
class MbtilesImporter {
  MbtilesImporter._();

  /// Hard ceiling on tiles written by one import. A regional pack is normally
  /// well under this; the cap stops a mis-picked global archive filling the
  /// phone in one tap.
  static const int maxTiles = 20000;

  /// Rows fetched per query.
  static const int pageSize = 400;

  /// Zooms accepted into the store (the map renders 2–18).
  static const int minZoom = 2;
  static const int maxZoom = 18;

  static Future<MbtilesImportResult> importFile(
    String path, {
    int maxTiles = maxTiles,
    void Function(int imported, int total)? onProgress,
    bool Function()? isCancelled,
  }) async {
    if (!await File(path).exists()) {
      return const MbtilesImportResult(
        imported: 0,
        skipped: 0,
        total: 0,
        zooms: [],
        error: 'File not found',
      );
    }

    Directory target;
    try {
      final docs = await getApplicationDocumentsDirectory();
      target = Directory('${docs.path}/offline_tiles');
      await target.create(recursive: true);
    } catch (e) {
      return MbtilesImportResult(
        imported: 0,
        skipped: 0,
        total: 0,
        zooms: const [],
        error: 'No storage available: $e',
      );
    }

    Database? db;
    try {
      db = await openDatabase(path, readOnly: true);
      final total = Sqflite.firstIntValue(
            await db.rawQuery('SELECT COUNT(*) FROM tiles'),
          ) ??
          0;
      final zoomRows = await db.rawQuery(
        'SELECT DISTINCT zoom_level AS z FROM tiles ORDER BY z',
      );
      final zooms = [
        for (final row in zoomRows)
          if ((row['z'] as num?)?.toInt() != null &&
              (row['z'] as num).toInt() >= minZoom &&
              (row['z'] as num).toInt() <= maxZoom)
            (row['z'] as num).toInt(),
      ];

      var imported = 0;
      var skipped = 0;
      var offset = 0;

      while (imported < maxTiles) {
        if (isCancelled?.call() == true) {
          return MbtilesImportResult(
            imported: imported,
            skipped: skipped,
            total: total,
            zooms: zooms,
            cancelled: true,
          );
        }
        final rows = await db.rawQuery(
          'SELECT zoom_level, tile_column, tile_row, tile_data FROM tiles '
          'WHERE zoom_level BETWEEN ? AND ? '
          'LIMIT ? OFFSET ?',
          [minZoom, maxZoom, pageSize, offset],
        );
        if (rows.isEmpty) break;
        offset += rows.length;

        for (final row in rows) {
          final z = (row['zoom_level'] as num).toInt();
          final x = (row['tile_column'] as num).toInt();
          final tmsY = (row['tile_row'] as num).toInt();
          final data = row['tile_data'];
          if (data is! Uint8List || data.isEmpty) continue;
          final y = (1 << z) - 1 - tmsY;
          final file = File('${target.path}/$z/$x/$y.png');
          if (await file.exists() && await file.length() > 0) {
            skipped++;
            continue;
          }
          await file.parent.create(recursive: true);
          await file.writeAsBytes(data, flush: false);
          imported++;
          if (imported >= maxTiles) break;
        }
        onProgress?.call(imported, total);
      }

      return MbtilesImportResult(
        imported: imported,
        skipped: skipped,
        total: total,
        zooms: zooms,
      );
    } catch (e) {
      return MbtilesImportResult(
        imported: 0,
        skipped: 0,
        total: 0,
        zooms: const [],
        error: 'Could not read MBTiles archive: $e',
      );
    } finally {
      await db?.close();
    }
  }

  /// Number of tiles currently installed, for the Settings summary.
  static Future<int> installedTileCount() async {
    try {
      final docs = await getApplicationDocumentsDirectory();
      final root = Directory('${docs.path}/offline_tiles');
      if (!await root.exists()) return 0;
      var count = 0;
      await for (final entity in root.list(recursive: true)) {
        if (entity is File && entity.path.endsWith('.png')) count++;
      }
      return count;
    } catch (_) {
      return 0;
    }
  }
}
