import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/theme.dart';
import '../state/incident.dart' show Need;
import '../state/relief_ledger.dart';
import '../state/transceiver_controller.dart';

/// Relief camp ledger: needs vs supplies on every camp heard over the mesh, and
/// a one-tap way to publish a new state from a camp post.
class ReliefScreen extends StatelessWidget {
  const ReliefScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final ctrl = context.watch<TransceiverController>();
    final ledger = ctrl.relief;
    final totals = ledger.shortfallTotals;
    final entries = ledger.entries;

    return Scaffold(
      appBar: AppBar(title: const Text('Relief ledger')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _showCampDialog(context, ctrl),
        icon: const Icon(Icons.add_business_outlined),
        label: const Text('Add camp'),
      ),
      body: Column(
        children: [
          if (totals.isNotEmpty) _ShortfallBar(totals: totals),
          Expanded(
            child: entries.isEmpty
                ? const _Empty()
                : ListView.separated(
                    padding: const EdgeInsets.fromLTRB(12, 12, 12, 96),
                    itemCount: entries.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 8),
                    itemBuilder: (context, i) => _CampCard(
                      entry: entries[i],
                      onShare: () => ctrl.sendReliefUpdate(
                        campId: entries[i].id,
                        name: entries[i].name,
                        lat: entries[i].lat,
                        lon: entries[i].lon,
                        needs: entries[i].needs,
                        supplies: entries[i].supplies,
                        note: entries[i].note,
                      ),
                      onDelete: () => ledger.remove(entries[i].id),
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

class _ShortfallBar extends StatelessWidget {
  const _ShortfallBar({required this.totals});

  final Map<Need, int> totals;

  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        color: SaharaTheme.danger.withValues(alpha: 0.12),
        child: Text(
          'Still needed across all camps: '
          '${totals.entries.map((e) => '${e.value} ${e.key.label.toLowerCase()}').join(' · ')}',
          style: const TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: SaharaTheme.danger,
          ),
        ),
      );
}

class _CampCard extends StatelessWidget {
  const _CampCard({
    required this.entry,
    required this.onShare,
    required this.onDelete,
  });

  final ReliefEntry entry;
  final VoidCallback onShare;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final age = DateTime.now().difference(entry.updatedAt);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.home_work_outlined,
                    size: 18, color: SaharaTheme.saffron),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    entry.name,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      color: SaharaTheme.textPrimary,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'Share over mesh',
                  icon: const Icon(Icons.cell_tower, size: 18),
                  onPressed: onShare,
                ),
                IconButton(
                  tooltip: 'Remove locally',
                  icon: const Icon(Icons.delete_outline, size: 18),
                  onPressed: onDelete,
                ),
              ],
            ),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final need in Need.values)
                  if ((entry.needs[need] ?? 0) > 0 ||
                      (entry.supplies[need] ?? 0) > 0)
                    _Chip(
                      label: '${need.label} '
                          '${entry.supplies[need] ?? 0}/'
                          '${entry.needs[need] ?? 0}',
                      bad: entry.balance(need) < 0,
                    ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              [
                if (entry.updatedBy.isNotEmpty) 'by ${entry.updatedBy}',
                age.inMinutes < 1 ? 'just now' : '${age.inMinutes} min ago',
                if (entry.note.isNotEmpty) entry.note,
              ].join(' · '),
              style: const TextStyle(
                fontSize: 10,
                color: SaharaTheme.textMuted,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.label, required this.bad});

  final String label;
  final bool bad;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: (bad ? SaharaTheme.danger : SaharaTheme.success)
              .withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: bad ? SaharaTheme.danger : SaharaTheme.success,
          ),
        ),
      );
}

class _Empty extends StatelessWidget {
  const _Empty();

  @override
  Widget build(BuildContext context) => const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'No camps yet. Add one with its water, food, medical, shelter and '
            'rescue counts; sharing it over the mesh lets every responder see '
            'the same shortfall without a server.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12, color: SaharaTheme.textMuted),
          ),
        ),
      );
}

Future<void> _showCampDialog(
  BuildContext context,
  TransceiverController ctrl,
) async {
  final nameCtrl = TextEditingController();
  final noteCtrl = TextEditingController();
  final needCtrls = {for (final n in Need.values) n: TextEditingController()};
  final supplyCtrls = {for (final n in Need.values) n: TextEditingController()};

  final saved = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Relief camp'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameCtrl,
              decoration: const InputDecoration(labelText: 'Camp name'),
            ),
            const SizedBox(height: 8),
            for (final need in Need.values)
              Row(
                children: [
                  SizedBox(
                    width: 76,
                    child: Text(need.label,
                        style: const TextStyle(fontSize: 12)),
                  ),
                  Expanded(
                    child: TextField(
                      controller: needCtrls[need],
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: 'need',
                        isDense: true,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      controller: supplyCtrls[need],
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: 'have',
                        isDense: true,
                      ),
                    ),
                  ),
                ],
              ),
            const SizedBox(height: 8),
            TextField(
              controller: noteCtrl,
              maxLength: 60,
              decoration: const InputDecoration(
                labelText: 'Note (optional)',
                isDense: true,
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text('Save & share'),
        ),
      ],
    ),
  );

  if (saved == true) {
    final needs = <Need, int>{};
    final supplies = <Need, int>{};
    for (final need in Need.values) {
      final n = int.tryParse(needCtrls[need]!.text.trim()) ?? 0;
      final s = int.tryParse(supplyCtrls[need]!.text.trim()) ?? 0;
      if (n > 0) needs[need] = n;
      if (s > 0) supplies[need] = s;
    }
    await ctrl.sendReliefUpdate(
      name: nameCtrl.text,
      needs: needs,
      supplies: supplies,
      note: noteCtrl.text,
    );
  }

  nameCtrl.dispose();
  noteCtrl.dispose();
  for (final c in needCtrls.values) {
    c.dispose();
  }
  for (final c in supplyCtrls.values) {
    c.dispose();
  }
}
