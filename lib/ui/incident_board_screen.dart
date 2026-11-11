import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/theme.dart';
import '../state/incident.dart';
import '../state/transceiver_controller.dart';
import 'map_screen.dart';
import 'report_dialogs.dart';

/// Offline incident board — the coordination view (Pillar 2).
///
/// Every report heard over the mesh is aggregated here: SOS calls, needs
/// reports, safe/missing check-ins and early warnings. There is no server; the
/// board is what this phone knows, which is exactly what a responder holding
/// one phone needs. Reports are persisted, so the picture survives a restart.
class IncidentBoardScreen extends StatefulWidget {
  const IncidentBoardScreen({super.key});

  @override
  State<IncidentBoardScreen> createState() => _IncidentBoardScreenState();
}

class _IncidentBoardScreenState extends State<IncidentBoardScreen> {
  IncidentKind? _filter;

  @override
  Widget build(BuildContext context) {
    return Consumer<TransceiverController>(
      builder: (context, ctrl, _) {
        final board = ctrl.incidents;
        final counts = board.counts;
        final reports = _filter == null
            ? board.reports
            : board.byKind(_filter!);

        return Scaffold(
          appBar: AppBar(
            title: const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.hub_outlined, size: 20, color: SaharaTheme.saffron),
                SizedBox(width: 8),
                Text('Incident board'),
              ],
            ),
            actions: [
              IconButton(
                tooltip: 'Clear board',
                icon: const Icon(Icons.delete_sweep_outlined, size: 20),
                onPressed: board.isEmpty
                    ? null
                    : () => _confirmClear(context, ctrl),
              ),
            ],
          ),
          body: Column(
            children: [
              _CountsHeader(counts: counts, total: board.length),
              _NeedsRow(totals: board.needTotals),
              _FilterRow(
                selected: _filter,
                onSelected: (f) => setState(() => _filter = f),
              ),
              const Divider(height: 1),
              Expanded(
                child: reports.isEmpty
                    ? const _EmptyBoard()
                    : ListView.builder(
                        padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
                        itemCount: reports.length,
                        itemBuilder: (context, index) {
                          final report = reports[index];
                          return _IncidentCard(
                            report: report,
                            onMap: report.hasPosition
                                ? () => Navigator.of(context).push(
                                      MaterialPageRoute<void>(
                                        builder: (_) => MapScreen(
                                          lat: report.lat!,
                                          lon: report.lon!,
                                          label: report.sender ??
                                              report.summaryLine,
                                          timestamp: report.timestamp,
                                          sos: report.kind == IncidentKind.sos,
                                        ),
                                      ),
                                    )
                                : null,
                            onAssign: () async {
                              final sent = await showAssignDialog(
                                context,
                                ctrl,
                                report,
                              );
                              if (sent == true && context.mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                    content: Text('Responder assigned'),
                                  ),
                                );
                              }
                            },
                            onResolve: report.status == IncidentStatus.resolved
                                ? null
                                : () => ctrl.incidents.resolve(report.incidentId),
                          );
                        },
                      ),
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _confirmClear(
    BuildContext context,
    TransceiverController ctrl,
  ) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: SaharaTheme.surface,
        title: const Text('Clear the incident board?'),
        content: const Text(
          'Removes every report stored on this phone. Reports on other phones '
          'are not affected.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('CANCEL'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('CLEAR'),
          ),
        ],
      ),
    );
    if (ok == true) ctrl.incidents.clear();
  }
}

class _CountsHeader extends StatelessWidget {
  const _CountsHeader({required this.counts, required this.total});

  final IncidentCounts counts;
  final int total;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
      color: SaharaTheme.surface,
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          _Stat(
            label: 'SOS',
            value: counts.sos,
            color: SaharaTheme.danger,
          ),
          _Stat(
            label: 'Warnings',
            value: counts.warnings,
            color: SaharaTheme.saffron,
          ),
          _Stat(
            label: 'Safe',
            value: counts.safe,
            color: SaharaTheme.success,
          ),
          _Stat(
            label: 'Missing',
            value: counts.missing,
            color: SaharaTheme.textPrimary,
          ),
          _Stat(
            label: 'Injured',
            value: counts.injured,
            color: SaharaTheme.danger,
          ),
          _Stat(
            label: 'Reports',
            value: total,
            color: SaharaTheme.textMuted,
          ),
        ],
      ),
    );
  }
}

/// One aggregate number. Colour carries the meaning, so the label alone is
/// readable for someone who cannot distinguish the colours.
class _Stat extends StatelessWidget {
  const _Stat({
    required this.label,
    required this.value,
    required this.color,
  });

  final String label;
  final int value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '$value',
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w900,
              color: color,
            ),
          ),
          const SizedBox(width: 5),
          Text(
            label,
            style: const TextStyle(
              fontSize: 10,
              color: SaharaTheme.textMuted,
              letterSpacing: 0.4,
            ),
          ),
        ],
      ),
    );
  }
}

class _NeedsRow extends StatelessWidget {
  const _NeedsRow({required this.totals});

  final Map<Need, int> totals;

  @override
  Widget build(BuildContext context) {
    if (totals.isEmpty) return const SizedBox.shrink();
    return Container(
      width: double.infinity,
      color: SaharaTheme.surface,
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
      child: Wrap(
        spacing: 6,
        runSpacing: 6,
        children: [
          for (final need in Need.values)
            if ((totals[need] ?? 0) > 0)
              Chip(
                visualDensity: VisualDensity.compact,
                label: Text(
                  '${need.label} ×${totals[need]}',
                  style: const TextStyle(fontSize: 10),
                ),
              ),
        ],
      ),
    );
  }
}

class _FilterRow extends StatelessWidget {
  const _FilterRow({required this.selected, required this.onSelected});

  final IncidentKind? selected;
  final ValueChanged<IncidentKind?> onSelected;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 10),
      child: Row(
        children: [
          _chip('All', null),
          _chip('SOS', IncidentKind.sos),
          _chip('Needs', IncidentKind.status),
          _chip('Check-ins', IncidentKind.checkIn),
          _chip('Warnings', IncidentKind.warning),
        ],
      ),
    );
  }

  Widget _chip(String label, IncidentKind? kind) {
    final on = selected == kind;
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: FilterChip(
        label: Text(label, style: const TextStyle(fontSize: 11)),
        selected: on,
        onSelected: (_) => onSelected(kind),
      ),
    );
  }
}

class _IncidentCard extends StatelessWidget {
  const _IncidentCard({
    required this.report,
    required this.onMap,
    required this.onAssign,
    required this.onResolve,
  });

  final IncidentReport report;
  final VoidCallback? onMap;
  final VoidCallback onAssign;
  final VoidCallback? onResolve;

  Color get _color => switch (report.kind) {
        IncidentKind.sos => SaharaTheme.danger,
        IncidentKind.warning => SaharaTheme.saffron,
        IncidentKind.checkIn =>
          report.safe ? SaharaTheme.success : SaharaTheme.danger,
        _ => report.severity >= 2
            ? SaharaTheme.saffron
            : SaharaTheme.textMuted,
      };

  String get _kindLabel => switch (report.kind) {
        IncidentKind.sos => 'SOS',
        IncidentKind.warning => 'WARNING',
        IncidentKind.checkIn => report.safe ? 'SAFE' : 'NOT SAFE',
        IncidentKind.status => 'NEEDS',
        IncidentKind.assignment => 'ASSIGNED',
      };

  String get _time {
    final d = DateTime.now().difference(report.timestamp);
    if (d.inMinutes < 1) return 'now';
    if (d.inMinutes < 60) return '${d.inMinutes}m';
    if (d.inHours < 24) return '${d.inHours}h';
    return '${d.inDays}d';
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: SaharaTheme.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: report.status == IncidentStatus.resolved
              ? SaharaTheme.border
              : _color.withValues(alpha: 0.45),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
            child: Row(
              children: [
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: _color.withValues(alpha: 0.18),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    _kindLabel,
                    style: TextStyle(
                      fontSize: 9,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 0.8,
                      color: _color,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    report.sender ?? 'Unknown sender',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: SaharaTheme.textPrimary,
                    ),
                  ),
                ),
                Text(
                  _time,
                  style: const TextStyle(
                    fontSize: 10,
                    color: SaharaTheme.textMuted,
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            child: Text(
              report.summaryLine,
              style: TextStyle(
                fontSize: 13,
                height: 1.35,
                color: report.status == IncidentStatus.resolved
                    ? SaharaTheme.textMuted
                    : SaharaTheme.textPrimary,
                decoration: report.status == IncidentStatus.resolved
                    ? TextDecoration.lineThrough
                    : null,
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            child: Wrap(
              spacing: 6,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                if (report.kind != IncidentKind.checkIn)
                  _Meta('${report.severityLabel} severity'),
                if (report.needs.isNotEmpty)
                  _Meta(report.needs.map((n) => n.label).join(' · ')),
                if (report.assignedTeam != null)
                  _Meta(
                    '${report.assignedTeam}'
                    '${report.etaMinutes == null ? '' : ' · ETA ${report.etaMinutes}m'}',
                  ),
                if (report.battery != null) _Meta('Bat ${report.battery}%'),
                if (report.hops != null && report.hops! > 0)
                  _Meta('${report.hops} hops'),
                if (report.status == IncidentStatus.resolved)
                  const _Meta('Resolved'),
              ],
            ),
          ),
          const Divider(height: 1),
          Row(
            children: [
              if (onMap != null)
                TextButton.icon(
                  onPressed: onMap,
                  icon: const Icon(Icons.map_outlined, size: 16),
                  label: const Text('MAP', style: TextStyle(fontSize: 10)),
                ),
              TextButton.icon(
                onPressed: onAssign,
                icon: const Icon(Icons.assignment_ind_outlined, size: 16),
                label: const Text('ASSIGN', style: TextStyle(fontSize: 10)),
              ),
              const Spacer(),
              if (onResolve != null)
                TextButton.icon(
                  onPressed: onResolve,
                  icon: const Icon(Icons.check_circle_outline, size: 16),
                  label: const Text('RESOLVE', style: TextStyle(fontSize: 10)),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Meta extends StatelessWidget {
  const _Meta(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: const TextStyle(fontSize: 10, color: SaharaTheme.textMuted),
    );
  }
}

class _EmptyBoard extends StatelessWidget {
  const _EmptyBoard();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: const [
            Icon(Icons.hub_outlined, size: 44, color: SaharaTheme.textMuted),
            SizedBox(height: 12),
            Text(
              'No reports yet',
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w700,
                color: SaharaTheme.textPrimary,
              ),
            ),
            SizedBox(height: 6),
            Text(
              'SOS calls, needs reports, check-ins and warnings heard over the '
              'mesh appear here — no internet required.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: SaharaTheme.textMuted),
            ),
          ],
        ),
      ),
    );
  }
}
