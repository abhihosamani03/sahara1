import 'package:flutter/material.dart';

import '../../core/theme.dart';

/// Hold-to-talk PTT button.
///
/// Uses [Listener] (raw pointer events) instead of [GestureDetector] to
/// avoid a critical Flutter gesture-arena bug: when `isActive` flips to
/// false the moment recording starts, GestureDetector disposes the
/// TapGestureRecognizer that was tracking the finger and replaces it
/// with a fresh one that has no active gesture — so the release event
/// is silently lost and the button is permanently bricked.
///
/// Listener delivers onPointerDown/Up/Cancel directly through the
/// rendering pipeline, which tracks the pointer independently of
/// widget rebuilds.
/// Hold-to-talk OR Tap-to-talk Walkie-Talkie Button.
///
/// Supports both interaction models:
/// 1. Hold-to-talk: press & hold (> 400ms) to speak, release to send immediately.
/// 2. Tap-to-talk: tap (< 400ms) to start listening; button pulses in recording mode;
///    tap again when finished to send.
class PttButton extends StatefulWidget {
  final VoidCallback onPressed;
  final VoidCallback onReleased;
  final bool isActive;
  final bool isRecording;
  final bool isProcessing;

  const PttButton({
    super.key,
    required this.onPressed,
    required this.onReleased,
    required this.isActive,
    this.isRecording = false,
    this.isProcessing = false,
  });

  @override
  State<PttButton> createState() => _PttButtonState();
}

class _PttButtonState extends State<PttButton>
    with SingleTickerProviderStateMixin {
  late AnimationController _pulse;
  bool _holding = false;
  DateTime? _pointerDownTime;
  bool _toggleMode = false;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isListening = widget.isRecording || _holding || _toggleMode;

    return LayoutBuilder(
      builder: (context, constraints) {
        final size = constraints.maxWidth.clamp(130.0, 200.0);
        return Listener(
          onPointerDown: (_) {
            if (!widget.isActive || widget.isProcessing) return;

            // If already recording in toggle mode, a tap stops and sends!
            if (isListening && _toggleMode) {
              _holding = false;
              _toggleMode = false;
              setState(() {});
              widget.onReleased();
              return;
            }

            _pointerDownTime = DateTime.now();
            _holding = true;
            setState(() {});
            widget.onPressed();
          },
          onPointerUp: (_) {
            if (!_holding) return;
            final downTime = _pointerDownTime;
            final holdDuration = downTime != null
                ? DateTime.now().difference(downTime).inMilliseconds
                : 0;

            if (holdDuration < 380) {
              // Quick tap: latch into toggle recording mode so speech is never lost!
              _holding = false;
              _toggleMode = true;
              setState(() {});
            } else {
              // Held and released: send immediately.
              _holding = false;
              _toggleMode = false;
              setState(() {});
              widget.onReleased();
            }
          },
          onPointerCancel: (_) {
            if (_holding) {
              _holding = false;
              _toggleMode = false;
              setState(() {});
              widget.onReleased();
            }
          },
          child: AnimatedBuilder(
            animation: _pulse,
            builder: (context, child) {
              final pulseScale =
                  isListening ? 1.0 + _pulse.value * 0.08 : 1.0;
              final glowOpacity =
                  isListening ? 0.35 + _pulse.value * 0.35 : 0.0;

              return Container(
                width: size,
                height: size,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: SaharaTheme.saffron
                          .withValues(alpha: glowOpacity),
                      blurRadius: 32,
                      spreadRadius: 10,
                    ),
                  ],
                ),
                child: Transform.scale(
                  scale: pulseScale,
                  child: child,
                ),
              );
            },
            child: Container(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: isListening
                    ? const RadialGradient(
                        colors: [
                          SaharaTheme.saffron,
                          SaharaTheme.saffronDark,
                        ],
                      )
                    : null,
                color: isListening ? null : SaharaTheme.surfaceLight,
                border: Border.all(
                  color: isListening
                      ? SaharaTheme.saffronLight
                      : (widget.isActive
                          ? SaharaTheme.saffron
                          : SaharaTheme.border),
                  width: 3,
                ),
              ),
              child: Center(
                child: widget.isProcessing
                    ? const Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          SizedBox(
                            width: 32,
                            height: 32,
                            child: CircularProgressIndicator(
                              strokeWidth: 3,
                              color: SaharaTheme.saffron,
                            ),
                          ),
                          SizedBox(height: 8),
                          Text(
                            'TRANSCRIBING',
                            style: TextStyle(
                              fontSize: 9,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 1.2,
                              color: SaharaTheme.saffron,
                            ),
                          ),
                        ],
                      )
                    : isListening
                        ? const Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.mic,
                                size: 44,
                                color: SaharaTheme.ink,
                              ),
                              SizedBox(height: 4),
                              Text(
                                'TAP TO SEND',
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  fontSize: 10,
                                  fontWeight: FontWeight.w800,
                                  letterSpacing: 1.2,
                                  color: SaharaTheme.ink,
                                ),
                              ),
                            ],
                          )
                        : Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.mic,
                                size: 38,
                                color: widget.isActive
                                    ? SaharaTheme.saffron
                                    : SaharaTheme.textMuted,
                              ),
                              const SizedBox(height: 4),
                              Text(
                                widget.isActive
                                    ? 'HOLD OR TAP\nTO TALK'
                                    : 'OFFLINE',
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  fontSize: 10,
                                  fontWeight: FontWeight.w700,
                                  letterSpacing: 1.2,
                                  height: 1.2,
                                  color: widget.isActive
                                      ? SaharaTheme.saffron
                                      : SaharaTheme.textMuted,
                                ),
                              ),
                            ],
                          ),
              ),
            ),
          ),
        );
      },
    );
  }
}
