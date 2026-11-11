import 'package:flutter/material.dart';

import '../core/theme.dart';
import '../state/incident.dart';
import '../state/transceiver_controller.dart';

/// Modal report forms for the coordination features.
///
/// Every form validates locally and sends over the mesh; nothing here needs a
/// network or an account. The dialogs return `true` when the report was handed
/// to at least one peer, so the caller can show the right confirmation.

/// "I am safe" check-in, with a head count so a command post can total people.
Future<bool?> showCheckInDialog(
  BuildContext context,
  TransceiverController ctrl,
) {
  return showDialog<bool>(
    context: context,
    builder: (_) => _CheckInDialog(ctrl: ctrl),
  );
}

/// Structured triage record: victims, injured, needs, severity.
Future<bool?> showStatusReportDialog(
  BuildContext context,
  TransceiverController ctrl,
) {
  return showDialog<bool>(
    context: context,
    builder: (_) => _StatusReportDialog(ctrl: ctrl),
  );
}

/// Early-warning alert, spoken and alarmed on every receiver.
Future<bool?> showWarningDialog(
  BuildContext context,
  TransceiverController ctrl,
) {
  return showDialog<bool>(
    context: context,
    builder: (_) => _WarningDialog(ctrl: ctrl),
  );
}

/// Assign a team + ETA to one incident and push it back to the victim.
Future<bool?> showAssignDialog(
  BuildContext context,
  TransceiverController ctrl,
  IncidentReport incident,
) {
  return showDialog<bool>(
    context: context,
    builder: (_) => _AssignDialog(ctrl: ctrl, incident: incident),
  );
}

// ── Shared chrome ────────────────────────────────────────────────

class _DialogShell extends StatelessWidget {
  const _DialogShell({
    required this.title,
    required this.children,
    required this.onSend,
    this.sendLabel = 'SEND OVER MESH',
  });

  final String title;
  final List<Widget> children;
  final Future<void> Function() onSend;
  final String sendLabel;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: SaharaTheme.surface,
      title: Text(
        title,
        style: const TextStyle(
          fontSize: 16,
          fontWeight: FontWeight.w800,
          color: SaharaTheme.textPrimary,
        ),
      ),
      content: SizedBox(
        width: 360,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: children,
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('CANCEL'),
        ),
        FilledButton(
          onPressed: onSend,
          style: FilledButton.styleFrom(backgroundColor: SaharaTheme.saffron),
          child: Text(sendLabel),
        ),
      ],
    );
  }
}

class _LabeledField extends StatelessWidget {
  const _LabeledField({
    required this.label,
    required this.controller,
    this.hint,
    this.keyboardType,
    this.maxLines = 1,
  });

  final String label;
  final TextEditingController controller;
  final String? hint;
  final TextInputType? keyboardType;
  final int maxLines;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextField(
        controller: controller,
        keyboardType: keyboardType,
        maxLines: maxLines,
        style: const TextStyle(color: SaharaTheme.textPrimary, fontSize: 14),
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          isDense: true,
        ),
      ),
    );
  }
}

/// Severity selector used by the status and warning forms.
class _SeveritySelector extends StatelessWidget {
  const _SeveritySelector({
    required this.value,
    required this.onChanged,
  });

  final int value;
  final ValueChanged<int> onChanged;

  static const _labels = ['Low', 'Moderate', 'High', 'Critical'];

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'SEVERITY',
            style: TextStyle(
              fontSize: 10,
              letterSpacing: 1.2,
              fontWeight: FontWeight.w700,
              color: SaharaTheme.textMuted,
            ),
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 6,
            children: [
              for (var i = 0; i < _labels.length; i++)
                ChoiceChip(
                  label: Text(_labels[i]),
                  selected: value == i,
                  onSelected: (_) => onChanged(i),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

void _closeWithResult(BuildContext context, bool sent) {
  // Resolve the messenger *before* popping: after pop the dialog element is
  // deactivated and ScaffoldMessenger.of would throw.
  final messenger = ScaffoldMessenger.of(context);
  Navigator.of(context).pop(sent);
  messenger.showSnackBar(
    SnackBar(
      content: Text(
        sent
            ? 'Report handed to the mesh — waiting for a delivery receipt'
            : 'No peer in range — queued for automatic delivery',
      ),
      duration: const Duration(seconds: 3),
    ),
  );
}

// ── Check-in ─────────────────────────────────────────────────────

class _CheckInDialog extends StatefulWidget {
  const _CheckInDialog({required this.ctrl});
  final TransceiverController ctrl;

  @override
  State<_CheckInDialog> createState() => _CheckInDialogState();
}

class _CheckInDialogState extends State<_CheckInDialog> {
  bool _safe = true;
  int _here = 1;
  final _missing = TextEditingController();
  final _note = TextEditingController();
  bool _sending = false;

  @override
  void dispose() {
    _missing.dispose();
    _note.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    if (_sending) return;
    setState(() => _sending = true);
    final sent = await widget.ctrl.sendCheckIn(
      safe: _safe,
      peopleHere: _here,
      peopleMissing: int.tryParse(_missing.text.trim()) ?? 0,
      note: _note.text,
    );
    if (!mounted) return;
    setState(() => _sending = false);
    _closeWithResult(context, sent);
  }

  @override
  Widget build(BuildContext context) {
    return _DialogShell(
      title: 'Check in',
      onSend: _send,
      sendLabel: _sending ? 'SENDING…' : 'SEND CHECK-IN',
      children: [
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: _safe,
          activeThumbColor: SaharaTheme.saffron,
          title: const Text(
            'I am safe',
            style: TextStyle(color: SaharaTheme.textPrimary, fontSize: 14),
          ),
          subtitle: Text(
            _safe
                ? 'Tells the mesh you do not need rescue'
                : 'Raises a distress alert on every phone',
            style: const TextStyle(fontSize: 11, color: SaharaTheme.textMuted),
          ),
          onChanged: (v) => setState(() => _safe = v),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            const Expanded(
              child: Text(
                'People here',
                style: TextStyle(
                  color: SaharaTheme.textPrimary,
                  fontSize: 13,
                ),
              ),
            ),
            IconButton(
              onPressed: _here > 1 ? () => setState(() => _here--) : null,
              icon: const Icon(Icons.remove_circle_outline),
            ),
            Text(
              '$_here',
              style: const TextStyle(
                color: SaharaTheme.textPrimary,
                fontWeight: FontWeight.w800,
              ),
            ),
            IconButton(
              onPressed: _here < 999 ? () => setState(() => _here++) : null,
              icon: const Icon(Icons.add_circle_outline),
            ),
          ],
        ),
        _LabeledField(
          label: 'Missing people (optional)',
          controller: _missing,
          keyboardType: TextInputType.number,
        ),
        _LabeledField(
          label: 'Note (optional)',
          controller: _note,
          hint: 'e.g. shelter at the school, 3 injured',
          maxLines: 2,
        ),
      ],
    );
  }
}

// ── Status / needs ───────────────────────────────────────────────

class _StatusReportDialog extends StatefulWidget {
  const _StatusReportDialog({required this.ctrl});
  final TransceiverController ctrl;

  @override
  State<_StatusReportDialog> createState() => _StatusReportDialogState();
}

class _StatusReportDialogState extends State<_StatusReportDialog> {
  final _victims = TextEditingController();
  final _injured = TextEditingController();
  final _note = TextEditingController();
  final Set<Need> _needs = {};
  int _severity = 1;
  bool _sending = false;

  @override
  void dispose() {
    _victims.dispose();
    _injured.dispose();
    _note.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    if (_sending) return;
    setState(() => _sending = true);
    final sent = await widget.ctrl.sendStatusReport(
      victims: int.tryParse(_victims.text.trim()) ?? 0,
      injured: int.tryParse(_injured.text.trim()) ?? 0,
      needs: _needs,
      severity: _severity,
      note: _note.text,
    );
    if (!mounted) return;
    setState(() => _sending = false);
    _closeWithResult(context, sent);
  }

  @override
  Widget build(BuildContext context) {
    return _DialogShell(
      title: 'Report needs',
      onSend: _send,
      sendLabel: _sending ? 'SENDING…' : 'SEND REPORT',
      children: [
        Row(
          children: [
            Expanded(
              child: _LabeledField(
                label: 'Victims',
                controller: _victims,
                keyboardType: TextInputType.number,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _LabeledField(
                label: 'Injured',
                controller: _injured,
                keyboardType: TextInputType.number,
              ),
            ),
          ],
        ),
        const Text(
          'NEEDS',
          style: TextStyle(
            fontSize: 10,
            letterSpacing: 1.2,
            fontWeight: FontWeight.w700,
            color: SaharaTheme.textMuted,
          ),
        ),
        const SizedBox(height: 6),
        Wrap(
          spacing: 6,
          runSpacing: 4,
          children: [
            for (final need in Need.values)
              FilterChip(
                label: Text(need.label),
                selected: _needs.contains(need),
                onSelected: (on) => setState(() {
                  if (on) {
                    _needs.add(need);
                  } else {
                    _needs.remove(need);
                  }
                }),
              ),
          ],
        ),
        const SizedBox(height: 12),
        _SeveritySelector(
          value: _severity,
          onChanged: (v) => setState(() => _severity = v),
        ),
        _LabeledField(
          label: 'Details (optional)',
          controller: _note,
          hint: 'Landmark, access route, children, elderly',
          maxLines: 2,
        ),
      ],
    );
  }
}

// ── Early warning ────────────────────────────────────────────────

class _WarningDialog extends StatefulWidget {
  const _WarningDialog({required this.ctrl});
  final TransceiverController ctrl;

  @override
  State<_WarningDialog> createState() => _WarningDialogState();
}

class _WarningDialogState extends State<_WarningDialog> {
  final _message = TextEditingController();
  final _radius = TextEditingController(text: '10');
  int _severity = 2;
  int _expiryMinutes = 180;
  bool _sending = false;

  @override
  void dispose() {
    _message.dispose();
    _radius.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    if (_sending) return;
    if (_message.text.trim().isEmpty) return;
    setState(() => _sending = true);
    final sent = await widget.ctrl.sendWarning(
      message: _message.text,
      severity: _severity,
      radiusKm: double.tryParse(_radius.text.trim()) ?? 10,
      expiresMinutes: _expiryMinutes,
    );
    if (!mounted) return;
    setState(() => _sending = false);
    _closeWithResult(context, sent);
  }

  @override
  Widget build(BuildContext context) {
    return _DialogShell(
      title: 'Send early warning',
      onSend: _send,
      sendLabel: _sending ? 'SENDING…' : 'BROADCAST ALERT',
      children: [
        const Text(
          'Every phone in range raises its siren and speaks this warning — no '
          'internet needed at either end.',
          style: TextStyle(fontSize: 11, color: SaharaTheme.textMuted),
        ),
        const SizedBox(height: 12),
        _LabeledField(
          label: 'Warning',
          controller: _message,
          hint: 'e.g. Flood water rising near the river — move to the school',
          maxLines: 3,
        ),
        _LabeledField(
          label: 'Affected radius (km)',
          controller: _radius,
          keyboardType: TextInputType.number,
        ),
        _SeveritySelector(
          value: _severity,
          onChanged: (v) => setState(() => _severity = v),
        ),
        const Text(
          'VALID FOR',
          style: TextStyle(
            fontSize: 10,
            letterSpacing: 1.2,
            fontWeight: FontWeight.w700,
            color: SaharaTheme.textMuted,
          ),
        ),
        const SizedBox(height: 6),
        Wrap(
          spacing: 6,
          children: [
            for (final minutes in const [60, 180, 360, 720])
              ChoiceChip(
                label: Text(minutes < 120 ? '${minutes}m' : '${minutes ~/ 60}h'),
                selected: _expiryMinutes == minutes,
                onSelected: (_) => setState(() => _expiryMinutes = minutes),
              ),
          ],
        ),
      ],
    );
  }
}

// ── Assignment ───────────────────────────────────────────────────

class _AssignDialog extends StatefulWidget {
  const _AssignDialog({required this.ctrl, required this.incident});
  final TransceiverController ctrl;
  final IncidentReport incident;

  @override
  State<_AssignDialog> createState() => _AssignDialogState();
}

class _AssignDialogState extends State<_AssignDialog> {
  final _team = TextEditingController();
  final _eta = TextEditingController(text: '25');
  bool _sending = false;

  @override
  void dispose() {
    _team.dispose();
    _eta.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    if (_sending) return;
    if (_team.text.trim().isEmpty) return;
    setState(() => _sending = true);
    final sent = await widget.ctrl.assignResponder(
      incidentId: widget.incident.incidentId,
      team: _team.text,
      etaMinutes: int.tryParse(_eta.text.trim()) ?? 0,
    );
    if (!mounted) return;
    setState(() => _sending = false);
    _closeWithResult(context, sent);
  }

  @override
  Widget build(BuildContext context) {
    return _DialogShell(
      title: 'Assign responder',
      onSend: _send,
      sendLabel: _sending ? 'SENDING…' : 'ASSIGN + NOTIFY',
      children: [
        Text(
          widget.incident.summaryLine,
          style: const TextStyle(fontSize: 12, color: SaharaTheme.textMuted),
        ),
        const SizedBox(height: 12),
        _LabeledField(
          label: 'Team',
          controller: _team,
          hint: 'e.g. Rescue-2',
        ),
        _LabeledField(
          label: 'ETA (minutes)',
          controller: _eta,
          keyboardType: TextInputType.number,
        ),
        const Text(
          'The victim\'s phone shows the team and ETA, and the assignment is '
          'recorded on this board.',
          style: TextStyle(fontSize: 10, color: SaharaTheme.textMuted),
        ),
      ],
    );
  }
}
