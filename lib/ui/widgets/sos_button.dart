import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/theme.dart';

/// The SOS button.
///
/// Sending an emergency alert is irreversible and goes to every device in
/// range, so a single tap is never enough: tapping opens a confirmation sheet
/// that auto-cancels after [SosButton.confirmSeconds] unless the user commits.
/// That gets an SOS out fast under stress while still preventing pocket
/// triggers.
class SosButton extends StatelessWidget {
  const SosButton({
    super.key,
    required this.onSend,
    this.enabled = true,
    this.sending = false,
    this.confirmSeconds = 3,
  });

  /// Called with the optional note once the user confirms.
  final Future<bool> Function(String? note) onSend;

  final bool enabled;
  final bool sending;
  final int confirmSeconds;

  Future<void> _confirmAndSend(BuildContext context) async {
    final note = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _SosConfirmDialog(countdownSeconds: confirmSeconds),
    );
    // null = cancelled or the countdown expired.
    if (note == null) return;
    await onSend(note.trim().isEmpty ? null : note.trim());
  }

  @override
  Widget build(BuildContext context) {
    final active = enabled && !sending;
    return SizedBox(
      height: 46,
      child: ElevatedButton.icon(
        onPressed: active ? () => _confirmAndSend(context) : null,
        icon: sending
            ? const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Colors.white,
                ),
              )
            : const Icon(Icons.sos, size: 20),
        label: Text(
          sending ? 'SENDING…' : 'SOS',
          style: const TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w900,
            letterSpacing: 2,
          ),
        ),
        style: ElevatedButton.styleFrom(
          backgroundColor: SaharaTheme.danger,
          foregroundColor: Colors.white,
          disabledBackgroundColor:
              SaharaTheme.danger.withValues(alpha: 0.35),
          disabledForegroundColor: Colors.white70,
          elevation: 0,
          padding: const EdgeInsets.symmetric(horizontal: 18),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
            side: BorderSide(
              color: Colors.white.withValues(alpha: active ? 0.5 : 0.15),
              width: 1.5,
            ),
          ),
        ),
      ),
    );
  }
}

/// Confirmation sheet with an auto-cancel countdown.
class _SosConfirmDialog extends StatefulWidget {
  const _SosConfirmDialog({required this.countdownSeconds});

  final int countdownSeconds;

  @override
  State<_SosConfirmDialog> createState() => _SosConfirmDialogState();
}

class _SosConfirmDialogState extends State<_SosConfirmDialog> {
  late int _remaining = widget.countdownSeconds;
  Timer? _timer;
  final _noteController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) {
        t.cancel();
        return;
      }
      setState(() => _remaining--);
      if (_remaining <= 0) {
        t.cancel();
        // Auto-cancel: an accidental tap resolves to nothing.
        Navigator.of(context).pop<String>(null);
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _noteController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: SaharaTheme.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: SaharaTheme.danger.withValues(alpha: 0.6)),
      ),
      title: Row(
        children: [
          const Icon(Icons.warning_amber_rounded,
              color: SaharaTheme.danger, size: 26),
          const SizedBox(width: 8),
          const Expanded(
            child: Text(
              'Send SOS?',
              style: TextStyle(
                color: SaharaTheme.textPrimary,
                fontWeight: FontWeight.w800,
                fontSize: 18,
              ),
            ),
          ),
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Every nearby Sahara device will sound a loud alarm and speak '
            'your message — including devices whose app is closed, on silent '
            'mode, or in Do Not Disturb.',
            style: TextStyle(
              fontSize: 13,
              color: SaharaTheme.textSecondary,
              height: 1.35,
            ),
          ),
          const SizedBox(height: 14),
          TextField(
            controller: _noteController,
            maxLength: 80,
            autofocus: false,
            style: const TextStyle(
              fontSize: 13,
              color: SaharaTheme.textPrimary,
            ),
            decoration: InputDecoration(
              hintText: 'Optional: what is happening? (shown + spoken)',
              hintStyle: const TextStyle(
                fontSize: 12,
                color: SaharaTheme.textMuted,
              ),
              counterStyle: const TextStyle(
                fontSize: 10,
                color: SaharaTheme.textMuted,
              ),
              isDense: true,
              filled: true,
              fillColor: SaharaTheme.surfaceLight,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: const BorderSide(color: SaharaTheme.border),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: const BorderSide(color: SaharaTheme.border),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: const BorderSide(color: SaharaTheme.danger),
              ),
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop<String>(null),
          child: Text(
            'CANCEL (${_remaining}s)',
            style: const TextStyle(
              color: SaharaTheme.textMuted,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        ElevatedButton(
          onPressed: () =>
              Navigator.of(context).pop<String>(_noteController.text),
          style: ElevatedButton.styleFrom(
            backgroundColor: SaharaTheme.danger,
            foregroundColor: Colors.white,
          ),
          child: const Text(
            'SEND SOS',
            style: TextStyle(fontWeight: FontWeight.w800, letterSpacing: 1),
          ),
        ),
      ],
    );
  }
}
