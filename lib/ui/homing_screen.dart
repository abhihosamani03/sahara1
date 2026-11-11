import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/theme.dart';
import '../net/mesh_transport.dart';
import '../state/transceiver_controller.dart';

/// Coarse proximity homing.
///
/// BLE advertisements report an RSSI per peer. That is a *distance hint*, not a
/// bearing: walls, bodies and antenna orientation all change it, and there is
/// no direction information in the radio at all. The screen says so explicitly
/// instead of pretending to be a compass — walking until the strongest signal
/// gets you close, then you search visually.
class HomingScreen extends StatelessWidget {
  const HomingScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final ctrl = context.watch<TransceiverController>();
    final signals = List<PeerSignal>.of(ctrl.peerSignals)
      ..sort((a, b) => b.rssi.compareTo(a.rssi));

    return Scaffold(
      appBar: AppBar(title: const Text('Signal homing')),
      body: Column(
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            color: SaharaTheme.saffron.withValues(alpha: 0.1),
            child: const Text(
              'RSSI is a rough distance hint, not a direction. Walk slowly and '
              'watch the bars rise; when two peers overlap, the strongest one '
              'is likely nearest.',
              style: TextStyle(fontSize: 11, color: SaharaTheme.textMuted),
            ),
          ),
          Expanded(
            child: signals.isEmpty
                ? const Center(
                    child: Padding(
                      padding: EdgeInsets.all(24),
                      child: Text(
                        'No peer is advertising right now. Keep the other phone '
                        'awake with Sahara open, and make sure Bluetooth and '
                        'Location are on.',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 12,
                          color: SaharaTheme.textMuted,
                        ),
                      ),
                    ),
                  )
                : ListView.separated(
                    padding: const EdgeInsets.all(12),
                    itemCount: signals.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 8),
                    itemBuilder: (context, i) =>
                        _SignalTile(signal: signals[i], rank: i + 1),
                  ),
          ),
        ],
      ),
    );
  }
}

class _SignalTile extends StatelessWidget {
  const _SignalTile({required this.signal, required this.rank});

  final PeerSignal signal;
  final int rank;

  /// Map -100…-40 dBm to 0…1 for the bar.
  double get _strength => ((signal.rssi + 100) / 60).clamp(0.05, 1.0);

  @override
  Widget build(BuildContext context) {
    final color = _strength > 0.75
        ? SaharaTheme.success
        : _strength > 0.4
            ? SaharaTheme.saffron
            : SaharaTheme.textMuted;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            CircleAvatar(
              radius: 16,
              backgroundColor: color.withValues(alpha: 0.16),
              child: Text(
                '$rank',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                  color: color,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    signal.ble ? 'BLE peer' : 'Wi-Fi Direct peer',
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: SaharaTheme.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 4),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(3),
                    child: LinearProgressIndicator(
                      value: _strength,
                      minHeight: 6,
                      backgroundColor: SaharaTheme.border,
                      valueColor: AlwaysStoppedAnimation<Color>(color),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${signal.rssi} dBm · ${signal.id}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 10,
                      color: SaharaTheme.textMuted,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
