import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/theme.dart';

/// Full-screen emergency alarm overlay (ARCHITECTURE.md §2.3).
///
/// Non-dismissible — appears on emergency packets, pulses red, forces
/// screen wake, and auto-clears after [durationSeconds]. The label switches
/// between SOS and generic EMERGENCY based on how the alert was raised.
///
/// A keyword-triggered emergency alert runs for 5 seconds; an explicit SOS is
/// given a much longer window by the caller, because somebody is asking for
/// help and the screen should not go back to normal behind their back.
class AlarmOverlay extends StatefulWidget {
  final int durationSeconds;

  /// 'SOS' or 'EMERGENCY' — what the sender transmitted.
  final String label;

  /// The sender's message, if any.
  final String? text;

  /// Whether this is an explicit SOS packet (longer alert window).
  final bool sos;

  /// Name of the device that raised the alarm, when it transmitted one.
  final String? sender;

  /// Opens the offline map at the distress coordinates. Null when the packet
  /// carried no GPS fix.
  final VoidCallback? onViewMap;

  const AlarmOverlay({
    super.key,
    this.durationSeconds = 5,
    this.label = 'EMERGENCY',
    this.text,
    this.sos = false,
    this.sender,
    this.onViewMap,
  });

  @override
  State<AlarmOverlay> createState() => _AlarmOverlayState();
}

class _AlarmOverlayState extends State<AlarmOverlay>
    with SingleTickerProviderStateMixin {
  late AnimationController _pulse;
  late AnimationController _countdown;

  @override
  void initState() {
    super.initState();

    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 500),
    )..repeat(reverse: true);

    _countdown = AnimationController(
      vsync: this,
      duration: Duration(seconds: widget.durationSeconds),
    )..forward();

    // Keep screen on during alarm.
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  }

  @override
  void dispose() {
    _pulse.dispose();
    _countdown.dispose();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.black,
      child: AnimatedBuilder(
        animation: _pulse,
        builder: (context, _) {
          final opacity = 0.85 + _pulse.value * 0.15;
          return Container(
            color: SaharaTheme.danger.withValues(alpha: opacity),
            child: SafeArea(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  // Pulsing icon
                  AnimatedScale(
                    scale: 1.0 + _pulse.value * 0.15,
                    duration: const Duration(milliseconds: 200),
                    child: Icon(
                      widget.sos ? Icons.sos : Icons.warning_amber_rounded,
                      size: 80,
                      color: Colors.white,
                    ),
                  ),
                  const SizedBox(height: 24),

                  // Title — 'SOS' for an SOS packet, 'EMERGENCY' otherwise.
                  Text(
                    widget.label,
                    style: const TextStyle(
                      fontSize: 40,
                      fontWeight: FontWeight.w900,
                      color: Colors.white,
                      letterSpacing: 8,
                    ),
                  ),
                  const SizedBox(height: 12),

                  // Subtitle — names the sender when one was transmitted.
                  Text(
                    widget.sender != null && widget.sender!.isNotEmpty
                        ? '${widget.sos ? 'Emergency SOS' : 'Emergency'} from '
                            '${widget.sender}'
                        : widget.sos
                            ? 'Emergency SOS signal received'
                            : 'Emergency signal received',
                    style: TextStyle(
                      fontSize: 16,
                      color: Colors.white.withValues(alpha: 0.9),
                    ),
                  ),

                  // Sender's message
                  if (widget.text != null && widget.text!.isNotEmpty) ...[
                    const SizedBox(height: 20),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 32),
                      child: Container(
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                            color: Colors.white.withValues(alpha: 0.3),
                          ),
                        ),
                        child: Text(
                          widget.text!,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                            color: Colors.white,
                            height: 1.4,
                          ),
                        ),
                      ),
                    ),
                  ],
                  // Offline map entry point — only when a fix came in.
                  if (widget.onViewMap != null) ...[
                    const SizedBox(height: 20),
                    OutlinedButton.icon(
                      onPressed: widget.onViewMap,
                      icon: const Icon(Icons.map_outlined, size: 18),
                      label: const Text('VIEW POSITION ON MAP'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.white,
                        side: BorderSide(
                          color: Colors.white.withValues(alpha: 0.55),
                        ),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 18,
                          vertical: 12,
                        ),
                      ),
                    ),
                  ],

                  const SizedBox(height: 28),

                  // Countdown bar
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 60),
                    child: AnimatedBuilder(
                      animation: _countdown,
                      builder: (context, _) {
                        return Column(
                          children: [
                            LinearProgressIndicator(
                              value: 1.0 - _countdown.value,
                              backgroundColor:
                                  Colors.white.withValues(alpha: 0.3),
                              valueColor:
                                  const AlwaysStoppedAnimation(Colors.white),
                              minHeight: 6,
                              borderRadius: BorderRadius.circular(3),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              'Auto-clears in ${((1.0 - _countdown.value) * widget.durationSeconds).ceil()}s',
                              style: TextStyle(
                                fontSize: 12,
                                color: Colors.white.withValues(alpha: 0.7),
                              ),
                            ),
                          ],
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}
