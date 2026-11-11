import 'package:flutter/material.dart';

import '../../core/theme.dart';
import '../../state/transceiver_controller.dart';

/// Horizontal pipeline strip showing the five stages:
/// STT → Encode → TX → Decode → TTS
///
/// Active stages glow saffron; idle stages are muted.
class PipelineStrip extends StatelessWidget {
  final TransceiverPhase phase;
  final String interimText;
  final int? sttMs;
  final int? transferMs;
  final int? ttsMs;

  const PipelineStrip({
    super.key,
    required this.phase,
    required this.interimText,
    this.sttMs,
    this.transferMs,
    this.ttsMs,
  });

  @override
  Widget build(BuildContext context) {
    final isDownloading = interimText.isNotEmpty &&
        (interimText.startsWith('Downloading') || interimText.startsWith('Preparing'));

    final stages = [
      _Stage('STT', Icons.record_voice_over,
          phase == TransceiverPhase.recording || isDownloading),
      _Stage('Encode', Icons.code, phase == TransceiverPhase.processing),
      _Stage('TX', Icons.send, phase == TransceiverPhase.transmitting),
      _Stage('Decode', Icons.input, false), // decode is instantaneous in loopback
      _Stage('TTS', Icons.volume_up, false), // TTS runs on receive only
    ];

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: SaharaTheme.surface,
        border: Border.all(color: SaharaTheme.border),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Pipeline stages
          Row(
            children: [
              for (var i = 0; i < stages.length; i++) ...[
                if (i > 0)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: Icon(
                      Icons.chevron_right,
                      size: 14,
                      color: stages[i - 1].active
                          ? SaharaTheme.saffron
                          : SaharaTheme.textMuted,
                    ),
                  ),
                _StageChip(stage: stages[i]),
              ],
            ],
          ),

          // Interim text (live STT output or download status)
          if (interimText.isNotEmpty) ...[
            const SizedBox(height: 8),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: SaharaTheme.ink,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Row(
                children: [
                  if (isDownloading) ...[
                    const SizedBox(
                      width: 12,
                      height: 12,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: SaharaTheme.saffron,
                      ),
                    ),
                    const SizedBox(width: 8),
                  ],
                  Expanded(
                    child: Text(
                      interimText,
                      style: TextStyle(
                        fontSize: 13,
                        color: isDownloading
                            ? SaharaTheme.saffron
                            : SaharaTheme.textPrimary,
                        fontStyle: isDownloading ? FontStyle.normal : FontStyle.italic,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
          ],

          // Timing row
          if (sttMs != null || transferMs != null || ttsMs != null) ...[
            const SizedBox(height: 6),
            Row(
              children: [
                if (sttMs != null)
                  _TimingChip(label: 'STT', ms: sttMs!),
                if (transferMs != null) ...[
                  const SizedBox(width: 6),
                  _TimingChip(label: 'TX', ms: transferMs!),
                ],
                if (ttsMs != null) ...[
                  const SizedBox(width: 6),
                  _TimingChip(label: 'TTS', ms: ttsMs!),
                ],
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _Stage {
  final String label;
  final IconData icon;
  final bool active;
  _Stage(this.label, this.icon, this.active);
}

class _StageChip extends StatelessWidget {
  final _Stage stage;
  const _StageChip({required this.stage});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          stage.icon,
          size: 14,
          color: stage.active ? SaharaTheme.saffron : SaharaTheme.textMuted,
        ),
        const SizedBox(width: 3),
        Text(
          stage.label,
          style: TextStyle(
            fontSize: 11,
            fontWeight: stage.active ? FontWeight.w700 : FontWeight.w500,
            color: stage.active ? SaharaTheme.saffron : SaharaTheme.textMuted,
          ),
        ),
      ],
    );
  }
}

class _TimingChip extends StatelessWidget {
  final String label;
  final int ms;
  const _TimingChip({required this.label, required this.ms});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: SaharaTheme.ink,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        '$label ${ms}ms',
        style: const TextStyle(
          fontSize: 10,
          fontFamily: 'monospace',
          color: SaharaTheme.textSecondary,
        ),
      ),
    );
  }
}
