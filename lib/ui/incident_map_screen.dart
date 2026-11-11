import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/theme.dart';
import '../state/incident.dart';
import '../state/transceiver_controller.dart';
import 'widgets/offline_map.dart';

/// All positioned incidents plus every breadcrumb trail on one offline map.
///
/// This is the situational-awareness view: SOS calls, needs reports, check-ins
/// and warnings that carry GPS, over the same tile store the single-position
/// map uses. With no tiles installed the graticule still places every pin.
class IncidentMapScreen extends StatelessWidget {
  const IncidentMapScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final ctrl = context.watch<TransceiverController>();
    final reports = ctrl.incidents.reports.where((r) => r.hasPosition).toList();

    final markers = <MapMarker>[
      for (final report in reports)
        MapMarker(
          lat: report.lat!,
          lon: report.lon!,
          label: _shortLabel(report),
          color: _colorFor(report),
          sos: report.kind == IncidentKind.sos,
        ),
    ];

    // Centre on the most recent SOS, else the newest positioned report, else
    // a neutral point in central India.
    final anchor = reports.isEmpty
        ? null
        : (reports.firstWhere(
            (r) => r.kind == IncidentKind.sos,
            orElse: () => reports.first,
          ));

    final trails = <MapTrail>[];
    var colorIndex = 0;
    for (final entry in ctrl.breadcrumbs.trails.entries) {
      final points = entry.value;
      if (points.length < 2) continue;
      trails.add(MapTrail(
        label: entry.key,
        points: [
          for (final p in points) (lat: p.lat, lon: p.lon),
        ],
        color: _trailColors[colorIndex % _trailColors.length],
      ));
      colorIndex++;
    }

    return Scaffold(
      appBar: AppBar(
        title: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.map_outlined, size: 20, color: SaharaTheme.saffron),
            SizedBox(width: 8),
            Text('Incident map'),
          ],
        ),
      ),
      body: Column(
        children: [
          Expanded(
            child: OfflineMapView(
              lat: anchor?.lat ?? 21.0,
              lon: anchor?.lon ?? 78.0,
              initialZoom: anchor == null ? 4 : 14,
              markers: markers,
              trails: trails,
            ),
          ),
          _Legend(
            markerCount: markers.length,
            trailCount: trails.length,
            source: ctrl.meshClockLabel,
          ),
        ],
      ),
    );
  }

  static String _shortLabel(IncidentReport report) {
    final who = report.sender ?? 'Unknown';
    return switch (report.kind) {
      IncidentKind.sos => 'SOS · $who',
      IncidentKind.warning => 'Warning · $who',
      IncidentKind.checkIn => (report.safe ? 'Safe · ' : 'Not safe · ') + who,
      IncidentKind.status => 'Needs · $who',
      IncidentKind.assignment => 'Assigned · $who',
    };
  }

  static Color _colorFor(IncidentReport report) => switch (report.kind) {
        IncidentKind.sos => SaharaTheme.danger,
        IncidentKind.warning => SaharaTheme.saffron,
        IncidentKind.checkIn =>
          report.safe ? SaharaTheme.success : SaharaTheme.danger,
        _ => report.severity >= 2 ? SaharaTheme.saffron : SaharaTheme.textMuted,
      };

  static const List<Color> _trailColors = [
    SaharaTheme.saffron,
    Color(0xFF64B5F6),
    Color(0xFF81C784),
    Color(0xFFBA68C8),
    Color(0xFF4DD0E1),
  ];
}

class _Legend extends StatelessWidget {
  const _Legend({
    required this.markerCount,
    required this.trailCount,
    required this.source,
  });

  final int markerCount;
  final int trailCount;
  final String source;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 18),
      decoration: const BoxDecoration(
        color: SaharaTheme.surface,
        border: Border(top: BorderSide(color: SaharaTheme.border)),
      ),
      child: Wrap(
        spacing: 14,
        runSpacing: 6,
        children: [
          _LegendItem(color: SaharaTheme.danger, text: 'SOS'),
          _LegendItem(color: SaharaTheme.saffron, text: 'Warning / needs'),
          _LegendItem(color: SaharaTheme.success, text: 'Safe'),
          Text(
            '$markerCount pins · $trailCount trails · $source',
            style: const TextStyle(
              fontSize: 10,
              color: SaharaTheme.textMuted,
            ),
          ),
        ],
      ),
    );
  }
}

class _LegendItem extends StatelessWidget {
  const _LegendItem({required this.color, required this.text});

  final Color color;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 9,
          height: 9,
          decoration: BoxDecoration(shape: BoxShape.circle, color: color),
        ),
        const SizedBox(width: 5),
        Text(
          text,
          style: const TextStyle(fontSize: 10, color: SaharaTheme.textMuted),
        ),
      ],
    );
  }
}
