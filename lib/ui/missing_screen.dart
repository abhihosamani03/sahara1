import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/theme.dart';
import '../state/missing_registry.dart';
import '../state/transceiver_controller.dart';

/// Missing-person registry shared over the mesh.
///
/// Records travel as text. A thumbnail is kept on the reporting phone only:
/// sending a few-kilobyte image would take ~20 frames and crowd out live SOS
/// traffic, so a relayed record says plainly that the photo is on the
/// reporter's device.
class MissingScreen extends StatelessWidget {
  const MissingScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final ctrl = context.watch<TransceiverController>();
    final registry = ctrl.missing;
    final people = registry.entries;

    return Scaffold(
      appBar: AppBar(title: const Text('Missing persons')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _showReportDialog(context, ctrl),
        icon: const Icon(Icons.person_search_outlined),
        label: const Text('Report'),
      ),
      body: people.isEmpty
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  'No missing-person reports yet. A report carries name, age, '
                  'last-seen place and a note; it is merged into every nearby '
                  'phone by recency.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 12,
                    color: SaharaTheme.textMuted,
                  ),
                ),
              ),
            )
          : ListView.separated(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 96),
              itemCount: people.length,
              separatorBuilder: (_, _) => const SizedBox(height: 8),
              itemBuilder: (context, i) => _PersonCard(
                person: people[i],
                onShare: () => ctrl.sendMissingPerson(
                  id: people[i].id,
                  name: people[i].name,
                  age: people[i].age,
                  note: people[i].note,
                  lastSeen: people[i].lastSeen,
                  photoPath: people[i].photoPath,
                ),
                onDelete: () => registry.remove(people[i].id),
              ),
            ),
    );
  }
}

class _PersonCard extends StatelessWidget {
  const _PersonCard({
    required this.person,
    required this.onShare,
    required this.onDelete,
  });

  final MissingPerson person;
  final VoidCallback onShare;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final photo = person.photoFile;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: SizedBox(
                width: 52,
                height: 52,
                child: photo != null
                    ? Image.file(
                        photo,
                        fit: BoxFit.cover,
                        errorBuilder: (_, _, _) =>
                            const _PhotoPlaceholder(local: true),
                      )
                    : const _PhotoPlaceholder(local: false),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    person.age == null
                        ? person.name
                        : '${person.name}, ${person.age}',
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      color: SaharaTheme.textPrimary,
                    ),
                  ),
                  if (person.lastSeen.isNotEmpty)
                    Text(
                      'Last seen: ${person.lastSeen}',
                      style: const TextStyle(
                        fontSize: 11,
                        color: SaharaTheme.textSecondary,
                      ),
                    ),
                  if (person.note.isNotEmpty)
                    Text(
                      person.note,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 11,
                        color: SaharaTheme.textMuted,
                      ),
                    ),
                  if (photo == null)
                    const Text(
                      'Photo stays on the reporting phone',
                      style: TextStyle(
                        fontSize: 9,
                        color: SaharaTheme.textMuted,
                        fontStyle: FontStyle.italic,
                      ),
                    ),
                ],
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
      ),
    );
  }
}

class _PhotoPlaceholder extends StatelessWidget {
  const _PhotoPlaceholder({required this.local});

  final bool local;

  @override
  Widget build(BuildContext context) => Container(
        color: SaharaTheme.surfaceLight,
        child: Icon(
          local ? Icons.broken_image_outlined : Icons.person_outline,
          size: 22,
          color: SaharaTheme.textMuted,
        ),
      );
}

Future<void> _showReportDialog(
  BuildContext context,
  TransceiverController ctrl,
) async {
  final name = TextEditingController();
  final age = TextEditingController();
  final lastSeen = TextEditingController();
  final note = TextEditingController();
  final photo = TextEditingController();

  final saved = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Report missing person'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: name,
              decoration: const InputDecoration(labelText: 'Name'),
            ),
            TextField(
              controller: age,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Age (optional)'),
            ),
            TextField(
              controller: lastSeen,
              maxLength: 40,
              decoration: const InputDecoration(
                labelText: 'Last seen (village, landmark)',
                isDense: true,
              ),
            ),
            TextField(
              controller: note,
              maxLength: 60,
              decoration: const InputDecoration(
                labelText: 'Note (clothing, condition)',
                isDense: true,
              ),
            ),
            TextField(
              controller: photo,
              decoration: const InputDecoration(
                labelText: 'Local photo path (optional)',
                helperText: 'Kept on this phone; not transmitted.',
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
          child: const Text('Report'),
        ),
      ],
    ),
  );

  if (saved == true) {
    await ctrl.sendMissingPerson(
      name: name.text,
      age: int.tryParse(age.text.trim()),
      lastSeen: lastSeen.text,
      note: note.text,
      photoPath: photo.text.trim().isEmpty ? null : photo.text.trim(),
    );
  }

  name.dispose();
  age.dispose();
  lastSeen.dispose();
  note.dispose();
  photo.dispose();
}
