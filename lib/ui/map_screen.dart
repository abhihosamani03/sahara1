import 'package:flutter/material.dart';

import '../core/theme.dart';
import '../net/osm_tiles.dart';
import 'widgets/offline_map.dart';

/// Full-screen offline map for one position carried in a packet.
///
/// The map itself ([OfflineMapView]) needs no network and no Google Maps key:
/// it reads XYZ tiles from the app's documents directory and, when none are
/// installed, still draws a graticule with the marker in the right place.
///
/// While a connection exists, one tap fetches the OpenStreetMap tiles around
/// this position into that same store, so the area stays available after the
/// network disappears.
class MapScreen extends StatefulWidget {
  const MapScreen({
    super.key,
    required this.lat,
    required this.lon,
    this.label,
    this.timestamp,
    this.sos = false,
  });

  /// Position carried in the packet.
  final double lat;
  final double lon;

  /// Sender's name, or a short description of where the fix came from.
  final String? label;

  /// When the packet was logged.
  final DateTime? timestamp;

  /// Whether this position came from an explicit SOS.
  final bool sos;

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  bool _downloading = false;

  /// Bumped after a download so [OfflineMapView] re-probes the tile store.
  int _tileEpoch = 0;

  Future<void> _downloadTiles() async {
    if (_downloading) return;
    setState(() => _downloading = true);
    final result = await OsmTileSource.downloadAround(
      lat: widget.lat,
      lon: widget.lon,
      zoom: 14,
    );
    if (!mounted) return;
    setState(() {
      _downloading = false;
      if (result.downloaded > 0) _tileEpoch++;
    });
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(result.ok
          ? '${result.message} — available offline'
          : result.message),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              widget.sos ? Icons.sos : Icons.place,
              size: 20,
              color: widget.sos ? SaharaTheme.danger : SaharaTheme.saffron,
            ),
            const SizedBox(width: 8),
            Text(widget.sos ? 'SOS position' : 'Position'),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton.small(
        tooltip: 'Download OpenStreetMap tiles for this area',
        onPressed: _downloading ? null : _downloadTiles,
        child: _downloading
            ? const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.download_for_offline_outlined, size: 20),
      ),
      body: Column(
        children: [
          Expanded(
            child: OfflineMapView(
              key: ValueKey<int>(_tileEpoch),
              lat: widget.lat,
              lon: widget.lon,
              label: widget.label,
            ),
          ),
          _PositionDetails(
            lat: widget.lat,
            lon: widget.lon,
            label: widget.label,
            timestamp: widget.timestamp,
            sos: widget.sos,
          ),
        ],
      ),
    );
  }
}

class _PositionDetails extends StatelessWidget {
  const _PositionDetails({
    required this.lat,
    required this.lon,
    required this.label,
    required this.timestamp,
    required this.sos,
  });

  final double lat;
  final double lon;
  final String? label;
  final DateTime? timestamp;
  final bool sos;

  @override
  Widget build(BuildContext context) {
    final time = timestamp;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
      decoration: BoxDecoration(
        color: SaharaTheme.surface,
        border: Border(
          top: BorderSide(
            color: sos
                ? SaharaTheme.danger.withValues(alpha: 0.5)
                : SaharaTheme.border,
          ),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (sos)
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: SaharaTheme.danger.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: const Text(
                    'SOS',
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w800,
                      color: SaharaTheme.danger,
                      letterSpacing: 1,
                    ),
                  ),
                ),
              if (sos) const SizedBox(width: 8),
              Expanded(
                child: Text(
                  label == null || label!.trim().isEmpty
                      ? 'Distress position'
                      : label!.trim(),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: SaharaTheme.textPrimary,
                  ),
                ),
              ),
              if (time != null)
                Text(
                  '${time.hour.toString().padLeft(2, '0')}:'
                  '${time.minute.toString().padLeft(2, '0')}',
                  style: const TextStyle(
                    fontSize: 11,
                    color: SaharaTheme.textMuted,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),
          SelectableText(
            '${lat.toStringAsFixed(6)}, ${lon.toStringAsFixed(6)}',
            style: const TextStyle(
              fontSize: 13,
              fontFamily: 'monospace',
              color: SaharaTheme.textPrimary,
            ),
          ),
          const SizedBox(height: 4),
          const Text(
            'Works with no internet. Use the download button while connected '
            'to cache OpenStreetMap tiles for this area (© OpenStreetMap '
            'contributors).',
            style: TextStyle(fontSize: 10, color: SaharaTheme.textMuted),
          ),
        ],
      ),
    );
  }
}
