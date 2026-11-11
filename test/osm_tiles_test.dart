import 'package:flutter_test/flutter_test.dart';
import 'package:itantra/net/osm_tiles.dart';

void main() {
  test('tile URL uses the standard XYZ template', () {
    expect(
      OsmTileSource.tileUri(14, 1234, 5678).toString(),
      'https://tile.openstreetmap.org/14/1234/5678.png',
    );
  });

  test('a descriptive user agent is set for the OSM policy', () {
    expect(OsmTileSource.userAgent, contains('Sahara'));
    expect(OsmTileSource.userAgent, isNot('Dart/3.0 (dart:io)'));
  });

  test('viewport tiles stay within the zoom grid and the cap', () {
    final tiles = OsmTileSource.viewportTiles(
      lat: 19.0760,
      lon: 72.8777,
      zoom: 14,
      widthPx: 1080,
      heightPx: 1920,
    );
    expect(tiles, isNotEmpty);
    expect(tiles.length, lessThanOrEqualTo(OsmTileSource.maxTiles));
    for (final tile in tiles) {
      expect(tile.z, 14);
      expect(tile.x, inInclusiveRange(0, (1 << 14) - 1));
      expect(tile.y, inInclusiveRange(0, (1 << 14) - 1));
    }
  });

  test('centre tile is included first', () {
    final tiles = OsmTileSource.viewportTiles(
      lat: 0,
      lon: 0,
      zoom: 2,
      widthPx: 256,
      heightPx: 256,
    );
    // Zoom 2, 256 px viewport around (0,0): tile (2,2).
    expect(tiles.first.z, 2);
    expect(tiles.first.x, 2);
    expect(tiles.first.y, 2);
  });

  test('longitude wraps at the antimeridian', () {
    final tiles = OsmTileSource.viewportTiles(
      lat: 0,
      lon: 179.9,
      zoom: 2,
      widthPx: 1024,
      heightPx: 256,
    );
    expect(tiles, isNotEmpty);
    for (final tile in tiles) {
      expect(tile.x, inInclusiveRange(0, 3));
    }
  });

  test('relative path matches the offline map tile store', () {
    expect(const OsmTileId(14, 1, 2).relativePath, '14/1/2.png');
  });
}
