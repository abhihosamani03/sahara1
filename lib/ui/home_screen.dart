import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/permissions.dart';
import '../core/theme.dart';
import '../ml/ibfs.dart';
import '../ml/languages.dart';
import '../net/mesh_transport.dart';
import '../state/app_settings.dart';
import '../state/transceiver_controller.dart';
import 'alerts_screen.dart';
import 'homing_screen.dart';
import 'incident_board_screen.dart';
import 'incident_map_screen.dart';
import 'missing_screen.dart';
import 'relief_screen.dart';
import 'map_screen.dart';
import 'report_dialogs.dart';
import 'settings_screen.dart';
import 'widgets/alarm_overlay.dart';
import 'widgets/pipeline_strip.dart';
import 'widgets/ptt_button.dart';
import 'widgets/sos_button.dart';

/// Main transceiver screen — the core UI for Sahara.
///
/// Layout (top to bottom):
/// - App bar with transceiver toggle
/// - Settings bar (sender/receiver language, GPS toggle)
/// - Pipeline strip (live STT → encode → TX → decode → TTS)
/// - PTT button (center)
/// - Packet log (scrollable list)
/// - Emergency alarm overlay (fullscreen, when active)
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  bool _transceiverOn = true;
  bool _permissionsChecked = false;
  final _textController = TextEditingController();
  final _textFocusNode = FocusNode();

  Timer? _meshTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _textController.addListener(() {
      if (mounted) setState(() {});
    });
    _requestPermissions();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final ctrl = Provider.of<TransceiverController>(context, listen: false);
      ctrl.predownloadModels(ctrl.senderLang);
    });

    // Auto-mesh background watcher: ensures BLE mesh stays active
    // whenever Bluetooth is turned on or permissions are granted.
    _meshTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      if (!mounted || !_transceiverOn) return;
      final ctrl = Provider.of<TransceiverController>(context, listen: false);
      if (!ctrl.meshActive) {
        ctrl.enableMesh();
      }
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Returning from a settings screen (DND access, battery optimisation):
    // re-read the native emergency state so the readiness strip updates.
    if (state == AppLifecycleState.resumed) {
      final ctrl =
          Provider.of<TransceiverController>(context, listen: false);
      ctrl.refreshEmergencyState();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _meshTimer?.cancel();
    _textController.dispose();
    _textFocusNode.dispose();
    super.dispose();
  }

  Future<void> _requestPermissions() async {
    if (_permissionsChecked) return;
    _permissionsChecked = true;

    final result = await PermissionManager.requestAll();
    if (mounted) {
      final ctrl = Provider.of<TransceiverController>(context, listen: false);
      // Immediately activate BLE mesh once Bluetooth/location permissions are granted
      if (result.bluetoothGranted || result.allGranted) {
        ctrl.enableMesh();
      }

      if (!result.allGranted) {
        final denied = result.denied.join(', ');
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Permissions needed: $denied'),
            duration: const Duration(seconds: 4),
            action: SnackBarAction(
              label: 'Retry',
              onPressed: () {
                _permissionsChecked = false;
                _requestPermissions();
              },
            ),
          ),
        );
      }
    }
  }

  /// Open the offline map for a position carried in a packet.
  ///
  /// Both entry points (a log card with a fix, and the alarm overlay) resolve
  /// here, so the map is reachable even with no tile pack installed.
  void _openMap({
    required double lat,
    required double lon,
    String? label,
    DateTime? timestamp,
    bool sos = false,
  }) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => MapScreen(
          lat: lat,
          lon: lon,
          label: label,
          timestamp: timestamp,
          sos: sos,
        ),
      ),
    );
  }

  /// Coordination menu: incident board, check-in, needs report, early warning
  /// and the repeating SOS beacon. All of it works over the mesh with no
  /// internet, so it lives one tap from the main screen rather than buried in
  /// Settings.
  Future<void> _onCoordinationAction(
    String action,
    TransceiverController ctrl,
  ) async {
    switch (action) {
      case 'board':
        await Navigator.of(context).push(
          MaterialPageRoute<void>(builder: (_) => const IncidentBoardScreen()),
        );
        break;
      case 'incident_map':
        await Navigator.of(context).push(
          MaterialPageRoute<void>(builder: (_) => const IncidentMapScreen()),
        );
        break;
      case 'checkin':
        await showCheckInDialog(context, ctrl);
        break;
      case 'status':
        await showStatusReportDialog(context, ctrl);
        break;
      case 'warning':
        await showWarningDialog(context, ctrl);
        break;
      case 'alerts':
        await Navigator.of(context).push(
          MaterialPageRoute<void>(builder: (_) => const AlertsScreen()),
        );
        break;
      case 'relief':
        await Navigator.of(context).push(
          MaterialPageRoute<void>(builder: (_) => const ReliefScreen()),
        );
        break;
      case 'homing':
        await Navigator.of(context).push(
          MaterialPageRoute<void>(builder: (_) => const HomingScreen()),
        );
        break;
      case 'missing':
        await Navigator.of(context).push(
          MaterialPageRoute<void>(builder: (_) => const MissingScreen()),
        );
        break;
      case 'voice':
        final wasRecording = ctrl.voiceNoteRecording;
        final ok = wasRecording
            ? await ctrl.stopAndSendVoiceNote()
            : await ctrl.startVoiceNote();
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(wasRecording
              ? (ok
                  ? 'Voice note sent over the mesh'
                  : 'Voice note could not be sent')
              : (ok
                  ? 'Recording — open the menu again to send'
                  : 'Microphone unavailable')),
        ));
        break;
      case 'beacon_start':
        final ok = await ctrl.startSosBeacon();
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              ok
                  ? 'SOS beacon started — repeats every 45 s until acknowledged'
                  : 'Beacon is already running',
            ),
          ),
        );
        break;
      case 'beacon_stop':
        ctrl.stopSosBeacon();
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<AppSettings>();
    return Consumer<TransceiverController>(
      builder: (context, ctrl, _) {
        // Confirm the radios came up, but do not nag while they are healthy.
        return Stack(
          children: [
            Scaffold(
              appBar: AppBar(
                title: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.cell_tower, size: 20, color: SaharaTheme.saffron),
                    SizedBox(width: 8),
                    Text('Sahara'),
                  ],
                ),
                actions: [
                  // Queue indicator
                  if (ctrl.hasQueuedMessages)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: Center(
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: SaharaTheme.saffron.withValues(alpha: 0.2),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            '📤 ${ctrl.queuedCount}',
                            style: const TextStyle(
                              fontSize: 11,
                              color: SaharaTheme.saffron,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ),
                    ),
                  // Live link badge: peer count across BLE + Wi-Fi Direct.
                  Padding(
                    padding: const EdgeInsets.only(right: 4),
                    child: Center(
                      child: _LinkBadge(stats: ctrl.linkStats),
                    ),
                  ),
                  // Coordination: incident board + structured reports.
                  PopupMenuButton<String>(
                    tooltip: 'Coordination',
                    icon: Badge(
                      isLabelVisible: ctrl.incidents.counts.sos > 0,
                      label: Text('${ctrl.incidents.counts.sos}'),
                      child: const Icon(Icons.hub_outlined, size: 20),
                    ),
                    onSelected: (value) =>
                        _onCoordinationAction(value, ctrl),
                    itemBuilder: (_) => <PopupMenuEntry<String>>[
                      PopupMenuItem(
                        value: 'board',
                        child: Text(
                          'Incident board (${ctrl.incidents.length})',
                        ),
                      ),
                      PopupMenuItem(
                        value: 'incident_map',
                        child: Text(
                          'Incident map (${ctrl.incidents.length} pins)',
                        ),
                      ),
                      const PopupMenuItem(
                        value: 'checkin',
                        child: Text("I'm safe — check in"),
                      ),
                      const PopupMenuItem(
                        value: 'status',
                        child: Text('Report needs / triage'),
                      ),
                      const PopupMenuItem(
                        value: 'warning',
                        child: Text('Send early warning'),
                      ),
                      const PopupMenuItem(
                        value: 'alerts',
                        child: Text('Early-warning feeds'),
                      ),
                      PopupMenuItem(
                        value: 'relief',
                        child: Text('Relief ledger (${ctrl.relief.length})'),
                      ),
                      PopupMenuItem(
                        value: 'homing',
                        child: Text(
                          'Signal homing (${ctrl.peerSignals.length})',
                        ),
                      ),
                      PopupMenuItem(
                        value: 'missing',
                        child: Text('Missing persons (${ctrl.missing.length})'),
                      ),
                      PopupMenuItem(
                        value: 'voice',
                        child: Text(ctrl.voiceNoteRecording
                            ? 'Send voice note now'
                            : 'Record voice note'),
                      ),
                      PopupMenuItem(
                        value: ctrl.beaconActive ? 'beacon_stop' : 'beacon_start',
                        child: Text(
                          ctrl.beaconActive
                              ? 'Stop SOS beacon (${ctrl.beaconSent}/${TransceiverController.kBeaconMaxRepeats})'
                              : 'Start SOS beacon',
                        ),
                      ),
                    ],
                  ),
                  // Settings
                  IconButton(
                    icon: const Icon(Icons.settings, size: 20),
                    tooltip: 'Settings',
                    onPressed: () {
                      Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => const SettingsScreen(),
                        ),
                      );
                    },
                  ),
                  // Transceiver toggle
                  Switch(
                    value: _transceiverOn,
                    onChanged: (v) {
                      setState(() => _transceiverOn = v);
                      if (v && !ctrl.modelsDownloading) {
                        ctrl.predownloadModels(ctrl.senderLang);
                      }
                    },
                    activeThumbColor: SaharaTheme.saffron,
                  ),
                  const SizedBox(width: 8),
                ],
              ),
              body: Column(
                children: [
                  // ── Settings Bar ──────────────────────────────
                  _SettingsBar(
                    enabled: _transceiverOn,
                    senderLang: ctrl.senderLang,
                    receiverLang: ctrl.receiverLang,
                    gpsEnabled: ctrl.gpsEnabled,
                    onSenderLangChanged: (l) => ctrl.senderLang = l,
                    onReceiverLangChanged: (l) => ctrl.receiverLang = l,
                    onGpsToggled: (v) => ctrl.gpsEnabled = v,
                  ),

                  // ── Mode / Role Bar ───────────────────────────
                  _ModeBar(
                    settings: settings,
                    handsFreeActive: ctrl.handsFreeActive,
                    onToggleMode: () {
                      settings.operationMode = settings.isHandsFree
                          ? OperationMode.walkieTalkie
                          : OperationMode.phone;
                    },
                    onOpenSettings: () {
                      Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => const SettingsScreen(),
                        ),
                      );
                    },
                  ),

                  // ── Relay-only banner ─────────────────────────
                  if (settings.relayMode)
                    Container(
                      width: double.infinity,
                      margin: const EdgeInsets.fromLTRB(16, 4, 16, 2),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 7),
                      decoration: BoxDecoration(
                        color: SaharaTheme.saffron.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: SaharaTheme.saffron.withValues(alpha: 0.45),
                        ),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.router_outlined,
                              size: 15, color: SaharaTheme.saffron),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              'RELAY ONLY — carrying traffic for nearby '
                              'phones. Mic and speaker are off.',
                              style: const TextStyle(
                                fontSize: 10,
                                fontWeight: FontWeight.w700,
                                color: SaharaTheme.saffron,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),

                  // ── Link Hint ─────────────────────────────────
                  // A radio that is up but has found nobody is the single most
                  // confusing state, so say what to check instead of showing a
                  // silent "searching" badge.
                  if (_transceiverOn &&
                      ctrl.meshActive &&
                      !ctrl.hasReachablePeer &&
                      ctrl.linkStats.searchHint.isNotEmpty)
                    _LinkHint(text: ctrl.linkStats.searchHint),

                  // ── Model Download Banner ─────────────────────
                  if (ctrl.modelsDownloading)
                    _ModelDownloadBanner(
                      progress: ctrl.modelsDownloadProgress,
                      status: ctrl.modelsDownloadStatus,
                    ),

                  // ── Pipeline Strip ────────────────────────────
                  Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 8),
                    child: PipelineStrip(
                      phase: ctrl.phase,
                      interimText: ctrl.interimText,
                      sttMs: ctrl.log.isNotEmpty ? ctrl.log.last.sttMs : null,
                      transferMs:
                          ctrl.log.isNotEmpty ? ctrl.log.last.transferMs : null,
                      ttsMs: ctrl.log.isNotEmpty ? ctrl.log.last.ttsMs : null,
                    ),
                  ),

                  // ── Transcription Preview + Correction ──────────
                  if (ctrl.interimText.isNotEmpty && ctrl.phase == TransceiverPhase.recording)
                    Container(
                      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: SaharaTheme.surface,
                        border: Border.all(color: SaharaTheme.saffron.withValues(alpha: 0.3)),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.edit_note, size: 18, color: SaharaTheme.saffron),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              ctrl.interimText,
                              style: const TextStyle(
                                fontSize: 14,
                                color: SaharaTheme.textPrimary,
                              ),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            'Release or tap to send',
                            style: TextStyle(
                              fontSize: 10,
                              color: SaharaTheme.saffron.withValues(alpha: 0.7),
                            ),
                          ),
                        ],
                      ),
                    ),

                  // ── Feedback / Notification Banner ────────────
                  if (ctrl.statusMessage != null && ctrl.phase == TransceiverPhase.idle)
                    Container(
                      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      decoration: BoxDecoration(
                        color: SaharaTheme.surface,
                        border: Border.all(color: Colors.amber.withValues(alpha: 0.5)),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.info_outline, size: 16, color: Colors.amber),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              ctrl.statusMessage!,
                              style: const TextStyle(
                                fontSize: 12,
                                color: SaharaTheme.textPrimary,
                              ),
                            ),
                          ),
                          IconButton(
                            icon: const Icon(Icons.close, size: 14, color: SaharaTheme.textMuted),
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(),
                            onPressed: () => ctrl.clearStatusMessage(),
                          ),
                        ],
                      ),
                    ),

                  // ── PTT Button ────────────────────────────────
                  Expanded(
                    flex: 2,
                    child: Center(child: _TalkArea(
                      transceiverOn: _transceiverOn,
                      ctrl: ctrl,
                      settings: settings,
                    )),
                  ),

                  // ── Model Download Button (when models not ready) ──
                  if (_transceiverOn && !ctrl.modelsDownloading && !ctrl.senderModelsReady)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                      child: SizedBox(
                        width: double.infinity,
                        child: ElevatedButton.icon(
                          onPressed: () => ctrl.downloadSenderModels(),
                          icon: const Icon(Icons.download, size: 18),
                          label: Text('Download ${ctrl.senderLang.name} offline models'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: SaharaTheme.saffron,
                            foregroundColor: SaharaTheme.ink,
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(8),
                            ),
                          ),
                        ),
                      ),
                    ),

                  // ── Model Status ──────────────────────────────
                  if (_transceiverOn && !ctrl.modelsDownloading && ctrl.modelsDownloadStatus.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
                      child: Text(
                        ctrl.modelsDownloadStatus,
                        style: TextStyle(
                          fontSize: 11,
                          color: ctrl.senderModelsReady
                              ? SaharaTheme.success
                              : SaharaTheme.textMuted,
                        ),
                      ),
                    ),

                  // ── TTS Voice Download Banner ─────────────────
                  if (ctrl.ttsDownloading)
                    _ModelDownloadBanner(
                      progress: ctrl.ttsDownloadProgress,
                      status: ctrl.ttsDownloadStatus,
                    ),

                  // ── Voice Ready / Manual Voice Download ───────
                  if (_transceiverOn &&
                      !ctrl.ttsDownloading &&
                      ctrl.ttsDownloadStatus.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
                      child: Text(
                        ctrl.ttsDownloadStatus,
                        style: TextStyle(
                          fontSize: 11,
                          color: ctrl.receiverTtsReady
                              ? SaharaTheme.success
                              : SaharaTheme.textMuted,
                        ),
                      ),
                    ),

                  // ── Typed Text Fallback ──────────────────────
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _textController,
                            focusNode: _textFocusNode,
                            // Typed messages don't need the STT model —
                            // always enabled when the transceiver is on and
                            // the state machine is idle.
                            enabled: _transceiverOn &&
                                ctrl.phase == TransceiverPhase.idle,
                            decoration: InputDecoration(
                              hintText: 'Type a message…',
                              hintStyle: const TextStyle(
                                fontSize: 13,
                                color: SaharaTheme.textMuted,
                              ),
                              contentPadding: const EdgeInsets.symmetric(
                                  horizontal: 12, vertical: 8),
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(8),
                                borderSide: const BorderSide(
                                    color: SaharaTheme.border),
                              ),
                              enabledBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(8),
                                borderSide: const BorderSide(
                                    color: SaharaTheme.border),
                              ),
                              focusedBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(8),
                                borderSide: const BorderSide(
                                    color: SaharaTheme.saffron),
                              ),
                              filled: true,
                              fillColor: SaharaTheme.surface,
                              suffixIcon: IconButton(
                                icon: const Icon(Icons.send,
                                    size: 18, color: SaharaTheme.saffron),
                                onPressed: _transceiverOn &&
                                        ctrl.phase == TransceiverPhase.idle &&
                                        _textController.text.trim().isNotEmpty
                                    ? () {
                                        final text = _textController.text.trim();
                                        _textController.clear();
                                        _textFocusNode.unfocus();
                                        setState(() {});
                                        ctrl.sendTypedText(text);
                                      }
                                    : null,
                              ),
                            ),
                            style: const TextStyle(
                              fontSize: 13,
                              color: SaharaTheme.textPrimary,
                            ),
                            onChanged: (_) => setState(() {}),
                            onSubmitted: (v) {
                              if (v.trim().isNotEmpty &&
                                  _transceiverOn &&
                                  ctrl.phase == TransceiverPhase.idle) {
                                _textController.clear();
                                setState(() {});
                                ctrl.sendTypedText(v.trim());
                              }
                            },
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 8),

                  // ── SOS + Emergency readiness ─────────────────
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Row(
                      children: [
                        SosButton(
                          enabled: _transceiverOn &&
                              ctrl.phase == TransceiverPhase.idle,
                          sending: ctrl.sosInFlight,
                          onSend: (note) => ctrl.sendSos(note: note),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: _EmergencyReadiness(
                            standbyActive: ctrl.standbyActive,
                            dndAccess: ctrl.dndAccess,
                            batteryExempt: ctrl.batteryExempt,
                            onOpenDnd: ctrl.openDndSettings,
                            onOpenBattery: ctrl.openBatterySettings,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 8),

                  // ── Packet Log ────────────────────────────────
                  Expanded(
                    flex: 3,
                    child: _PacketLog(
                      log: ctrl.log,
                      onOpenMap: (entry) => _openMap(
                        lat: entry.lat!,
                        lon: entry.lon!,
                        label: entry.senderName,
                        timestamp: entry.timestamp,
                        sos: entry.sos,
                      ),
                    ),
                  ),
                ],
              ),
            ),

            // ── Emergency Alarm Overlay ────────────────────────
            if (ctrl.alarmActive)
              AlarmOverlay(
                label: ctrl.alarmLabel,
                text: ctrl.alarmText,
                sos: ctrl.alarmIsSos,
                sender: ctrl.alarmSender,
                // 5 s for a keyword-triggered emergency alert; an explicit SOS
                // keeps ringing far longer because somebody needs help.
                durationSeconds: ctrl.alarmIsSos
                    ? TransceiverController.kSosAlertSeconds.inSeconds
                    : TransceiverController.kEmergencyAlertSeconds.inSeconds,
                onViewMap: ctrl.alarmHasPosition
                    ? () => _openMap(
                          lat: ctrl.alarmLat!,
                          lon: ctrl.alarmLon!,
                          label: ctrl.alarmSender,
                          sos: ctrl.alarmIsSos,
                        )
                    : null,
              ),
          ],
        );
      },
    );
  }
}

/// ── Emergency Readiness Strip ─────────────────────────────────

/// Compact row of SOS readiness chips.
///
/// Each chip is green when ready and amber-tappable when action is needed:
/// standby keeps reception alive with the app closed, DND access lets the
/// spoken message through Do Not Disturb, and battery exemption stops OEM
/// savers from killing standby.
class _EmergencyReadiness extends StatelessWidget {
  const _EmergencyReadiness({
    required this.standbyActive,
    required this.dndAccess,
    required this.batteryExempt,
    required this.onOpenDnd,
    required this.onOpenBattery,
  });

  final bool standbyActive;
  final bool dndAccess;
  final bool batteryExempt;
  final VoidCallback onOpenDnd;
  final VoidCallback onOpenBattery;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 6,
      runSpacing: 4,
      children: [
        _ReadinessChip(
          icon: Icons.notifications_active,
          label: 'Standby',
          ready: standbyActive,
          onTap: standbyActive ? null : onOpenBattery,
          tooltip: standbyActive
              ? 'Listening for SOS even when the app is closed'
              : 'Standby is off — tap to check battery settings',
        ),
        _ReadinessChip(
          icon: Icons.do_not_disturb_off,
          label: 'DND',
          ready: dndAccess,
          onTap: dndAccess ? null : onOpenDnd,
          tooltip: dndAccess
              ? 'SOS can lift Do Not Disturb and speak loudly'
              : 'Tap to grant DND access so SOS can speak through it',
        ),
        _ReadinessChip(
          icon: Icons.battery_saver,
          label: 'Battery',
          ready: batteryExempt,
          onTap: batteryExempt ? null : onOpenBattery,
          tooltip: batteryExempt
              ? 'Exempt from battery optimisation'
              : 'Tap to exempt Sahara from battery optimisation',
        ),
      ],
    );
  }
}

class _ReadinessChip extends StatelessWidget {
  const _ReadinessChip({
    required this.icon,
    required this.label,
    required this.ready,
    required this.onTap,
    required this.tooltip,
  });

  final IconData icon;
  final String label;
  final bool ready;
  final VoidCallback? onTap;
  final String tooltip;

  @override
  Widget build(BuildContext context) {
    final color = ready ? SaharaTheme.success : SaharaTheme.saffron;
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
          decoration: BoxDecoration(
            color: color.withValues(alpha: ready ? 0.12 : 0.08),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: color.withValues(alpha: ready ? 0.4 : 0.25),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 12, color: color),
              const SizedBox(width: 3),
              Text(
                label,
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                  color: color,
                ),
              ),
              if (!ready) ...[
                const SizedBox(width: 3),
                const Icon(Icons.arrow_forward_ios,
                    size: 8, color: SaharaTheme.textMuted),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// ── Link Badge ─────────────────────────────────────────────────

/// App-bar indicator for the radio state.
///
/// This replaces the old two-state `peers` / `offline` pill, which reported
/// "offline" even while both radios were up and merely still searching for a
/// peer — so an app that was working looked broken.
class _LinkBadge extends StatelessWidget {
  final LinkStats stats;

  const _LinkBadge({required this.stats});

  @override
  Widget build(BuildContext context) {
    final connected = stats.hasPeers;
    final live = stats.anyRunning;

    final Color color = connected
        ? SaharaTheme.success
        : live
            ? SaharaTheme.saffron
            : SaharaTheme.textMuted;

    final IconData icon = connected
        ? Icons.hub
        : live
            ? Icons.wifi_tethering
            : Icons.hub_outlined;

    return Tooltip(
      message: stats.detail,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: color.withValues(alpha: connected ? 0.15 : 0.08),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: connected
                ? color.withValues(alpha: 0.5)
                : SaharaTheme.border,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 13, color: color),
            const SizedBox(width: 3),
            Text(
              stats.label,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: color,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One-line, actionable guidance while the radios are up but peerless.
class _LinkHint extends StatelessWidget {
  final String text;

  const _LinkHint({required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 4),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: SaharaTheme.surface,
        border: Border.all(color: SaharaTheme.border),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.wifi_tethering,
              size: 14, color: SaharaTheme.textSecondary),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(
                fontSize: 11,
                color: SaharaTheme.textSecondary,
                height: 1.3,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// ── Model Download Banner ─────────────────────────────────────

class _ModelDownloadBanner extends StatelessWidget {
  final double progress;
  final String status;

  const _ModelDownloadBanner({
    required this.progress,
    required this.status,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: SaharaTheme.saffron.withValues(alpha: 0.1),
        border: Border(
          bottom: BorderSide(
            color: SaharaTheme.saffron.withValues(alpha: 0.3),
          ),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: SaharaTheme.saffron,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  status,
                  style: const TextStyle(
                    fontSize: 12,
                    color: SaharaTheme.saffron,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: LinearProgressIndicator(
              value: progress,
              minHeight: 4,
              backgroundColor: SaharaTheme.surfaceLight,
              valueColor: const AlwaysStoppedAnimation(SaharaTheme.saffron),
            ),
          ),
        ],
      ),
    );
  }
}

/// ── Settings Bar ───────────────────────────────────────────────

class _SettingsBar extends StatelessWidget {
  final bool enabled;
  final Lang senderLang;
  final Lang receiverLang;
  final bool gpsEnabled;
  final ValueChanged<Lang> onSenderLangChanged;
  final ValueChanged<Lang> onReceiverLangChanged;
  final ValueChanged<bool> onGpsToggled;

  const _SettingsBar({
    required this.enabled,
    required this.senderLang,
    required this.receiverLang,
    required this.gpsEnabled,
    required this.onSenderLangChanged,
    required this.onReceiverLangChanged,
    required this.onGpsToggled,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: const BoxDecoration(
        color: SaharaTheme.surface,
        border: Border(bottom: BorderSide(color: SaharaTheme.border)),
      ),
      child: Row(
        children: [
          // Sender language
          Expanded(
            child: _LangSelector(
              label: 'Speak',
              value: senderLang,
              enabled: enabled,
              onChanged: onSenderLangChanged,
            ),
          ),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 8),
            child: Icon(Icons.arrow_forward, size: 16, color: SaharaTheme.textMuted),
          ),
          // Receiver language
          Expanded(
            child: _LangSelector(
              label: 'Listen',
              value: receiverLang,
              enabled: enabled,
              onChanged: onReceiverLangChanged,
            ),
          ),
          const SizedBox(width: 12),
          // GPS toggle
          GestureDetector(
            onTap: enabled ? () => onGpsToggled(!gpsEnabled) : null,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.location_on,
                  size: 18,
                  color: gpsEnabled
                      ? SaharaTheme.saffron
                      : SaharaTheme.textMuted,
                ),
                const SizedBox(width: 4),
                Text(
                  'GPS',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: gpsEnabled
                        ? SaharaTheme.saffron
                        : SaharaTheme.textMuted,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _LangSelector extends StatelessWidget {
  final String label;
  final Lang value;
  final bool enabled;
  final ValueChanged<Lang> onChanged;

  const _LangSelector({
    required this.label,
    required this.value,
    required this.enabled,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          style: const TextStyle(
            fontSize: 10,
            fontWeight: FontWeight.w600,
            color: SaharaTheme.textMuted,
            letterSpacing: 1,
          ),
        ),
        const SizedBox(height: 2),
        DropdownButton<Lang>(
          value: value,
          isDense: true,
          isExpanded: true,
          underline: const SizedBox(),
          dropdownColor: SaharaTheme.surfaceLight,
          style: const TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: SaharaTheme.textPrimary,
          ),
          items: kLanguages
              .map((l) => DropdownMenuItem(value: l, child: Text(l.name)))
              .toList(),
          onChanged: enabled ? (l) { if (l != null) onChanged(l); } : null,
        ),
      ],
    );
  }
}

/// ── Packet Log ─────────────────────────────────────────────────

class _PacketLog extends StatelessWidget {
  final List<LogEntry> log;

  /// Opens the offline map for an entry that carries a position.
  final ValueChanged<LogEntry>? onOpenMap;

  const _PacketLog({required this.log, this.onOpenMap});

  @override
  Widget build(BuildContext context) {
    if (log.isEmpty) {
      return const Center(
        child: Text(
          'No packets yet\nHold the PTT button to send',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 14,
            color: SaharaTheme.textMuted,
          ),
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      itemCount: log.length,
      reverse: true, // newest at top
      itemBuilder: (context, index) {
        final entry = log[log.length - 1 - index];
        return _LogEntryCard(entry: entry, onOpenMap: onOpenMap);
      },
    );
  }
}

class _LogEntryCard extends StatelessWidget {
  final LogEntry entry;
  final ValueChanged<LogEntry>? onOpenMap;

  const _LogEntryCard({required this.entry, this.onOpenMap});

  @override
  Widget build(BuildContext context) {
    final isEmergency = entry.priority == Priority.emergency;
    final isError = entry.error != null;

    final card = Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: isError
            ? SaharaTheme.danger.withValues(alpha: 0.1)
            : isEmergency
                ? SaharaTheme.danger.withValues(alpha: 0.08)
                : SaharaTheme.surface,
        border: Border.all(
          color: isError
              ? SaharaTheme.danger.withValues(alpha: 0.4)
              : isEmergency
                  ? SaharaTheme.danger.withValues(alpha: 0.3)
                  : SaharaTheme.border,
        ),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header row
          Row(
            children: [
              Icon(
                entry.isSent ? Icons.arrow_upward : Icons.arrow_downward,
                size: 14,
                color: entry.isSent
                    ? SaharaTheme.saffron
                    : SaharaTheme.success,
              ),
              const SizedBox(width: 4),
              Text(
                entry.isSent ? 'SENT' : 'RECEIVED',
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  color: entry.isSent
                      ? SaharaTheme.saffron
                      : SaharaTheme.success,
                  letterSpacing: 1,
                ),
              ),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                decoration: BoxDecoration(
                  color: isEmergency
                      ? SaharaTheme.danger.withValues(alpha: 0.2)
                      : SaharaTheme.surfaceLight,
                  borderRadius: BorderRadius.circular(3),
                ),
                child: Text(
                  entry.langName,
                  style: TextStyle(
                    fontSize: 9,
                    fontWeight: FontWeight.w600,
                    color: isEmergency
                        ? SaharaTheme.danger
                        : SaharaTheme.textSecondary,
                  ),
                ),
              ),
              // Who sent it, when the sender transmitted a name.
              if (entry.senderName != null &&
                  entry.senderName!.isNotEmpty) ...[
                const SizedBox(width: 4),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                  decoration: BoxDecoration(
                    color: SaharaTheme.saffron.withValues(alpha: 0.18),
                    borderRadius: BorderRadius.circular(3),
                  ),
                  child: Text(
                    entry.senderName!,
                    style: const TextStyle(
                      fontSize: 9,
                      fontWeight: FontWeight.w700,
                      color: SaharaTheme.saffron,
                    ),
                  ),
                ),
              ],
              if (isEmergency) ...[
                const SizedBox(width: 4),
                const Icon(Icons.warning_amber_rounded,
                    size: 12, color: SaharaTheme.danger),
              ],
              if (entry.deliveryLabel != null) ...[
                const SizedBox(width: 4),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                  decoration: BoxDecoration(
                    color: (entry.acks > 0
                            ? SaharaTheme.success
                            : entry.awaitingAck
                                ? Colors.amber
                                : SaharaTheme.textMuted)
                        .withValues(alpha: 0.16),
                    borderRadius: BorderRadius.circular(3),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (entry.acks > 0)
                        const Icon(Icons.done_all,
                            size: 10, color: SaharaTheme.success)
                      else
                        const Icon(Icons.schedule,
                            size: 10, color: SaharaTheme.textMuted),
                      const SizedBox(width: 2),
                      Text(
                        entry.deliveryLabel!,
                        style: TextStyle(
                          fontSize: 9,
                          fontWeight: FontWeight.w700,
                          color: entry.acks > 0
                              ? SaharaTheme.success
                              : SaharaTheme.textMuted,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              const Spacer(),
              Text(
                _formatTime(entry.timestamp),
                style: const TextStyle(
                  fontSize: 10,
                  color: SaharaTheme.textMuted,
                ),
              ),
            ],
          ),

          // Text
          const SizedBox(height: 6),
          Text(
            entry.text,
            style: TextStyle(
              fontSize: 13,
              color: isError
                  ? SaharaTheme.danger
                  : SaharaTheme.textPrimary,
            ),
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
          ),

          // On-device translation, shown under the original text.
          if (entry.translated != null &&
              entry.translated!.trim().isNotEmpty) ...[
            const SizedBox(height: 4),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.translate,
                    size: 12, color: SaharaTheme.saffron),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    entry.translated!,
                    style: const TextStyle(
                      fontSize: 12,
                      fontStyle: FontStyle.italic,
                      color: SaharaTheme.saffron,
                    ),
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ],

          // Timing row
          if (entry.sttMs != null ||
              entry.transferMs != null ||
              entry.ttsMs != null ||
              entry.e2eMs != null) ...[
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              children: [
                if (entry.sttMs != null)
                  _Timing(label: 'STT', ms: entry.sttMs!),
                if (entry.transferMs != null)
                  _Timing(label: 'TX', ms: entry.transferMs!),
                if (entry.ttsMs != null)
                  _Timing(label: 'TTS', ms: entry.ttsMs!),
                // Recognizer-only time and its real-time factor. RTF below
                // 1.0 means transcription ran faster than real time.
                if (entry.decodeMs != null)
                  _Timing(label: 'ASR', ms: entry.decodeMs!),
                if (entry.rtf != null)
                  _Timing(
                    label: 'RTF',
                    ms: 0,
                    text: entry.rtf!.toStringAsFixed(2),
                  ),
                if (entry.e2eMs != null)
                  _Timing(label: 'E2E', ms: entry.e2eMs!, bold: true),
              ],
            ),
          ],

          // GPS coordinates
          if (entry.lat != null && entry.lon != null) ...[
            const SizedBox(height: 4),
            Row(
              children: [
                Icon(
                  Icons.location_on,
                  size: 11,
                  color: entry.hasPosition && onOpenMap != null
                      ? SaharaTheme.danger
                      : SaharaTheme.textMuted,
                ),
                const SizedBox(width: 3),
                Text(
                  '${entry.lat!.toStringAsFixed(4)}, ${entry.lon!.toStringAsFixed(4)}',
                  style: const TextStyle(
                    fontSize: 10,
                    fontFamily: 'monospace',
                    color: SaharaTheme.textMuted,
                  ),
                ),
                if (onOpenMap != null) ...[
                  const SizedBox(width: 6),
                  const Text(
                    'tap for map',
                    style: TextStyle(
                      fontSize: 9,
                      color: SaharaTheme.saffron,
                    ),
                  ),
                ],
              ],
            ),
          ],

          // Error / translation note
          if (isError) ...[
            const SizedBox(height: 4),
            Text(
              entry.error!,
              style: const TextStyle(
                fontSize: 10,
                color: SaharaTheme.danger,
                fontFamily: 'monospace',
              ),
            ),
          ],
        ],
      ),
    );

    // An entry with coordinates becomes the entry point to the offline map.
    if (entry.hasPosition && onOpenMap != null) {
      return InkWell(
        onTap: () => onOpenMap!(entry),
        borderRadius: BorderRadius.circular(8),
        child: card,
      );
    }
    return card;
  }

  String _formatTime(DateTime dt) {
    return '${dt.hour.toString().padLeft(2, '0')}:'
        '${dt.minute.toString().padLeft(2, '0')}:'
        '${dt.second.toString().padLeft(2, '0')}';
  }
}

class _Timing extends StatelessWidget {
  final String label;
  final int ms;
  final bool bold;

  /// Literal value shown instead of '$ms ms' (used for the unit-less RTF).
  final String? text;

  const _Timing({
    required this.label,
    required this.ms,
    this.bold = false,
    this.text,
  });

  @override
  Widget build(BuildContext context) {
    return Text(
      '$label ${text ?? '${ms}ms'}',
      style: TextStyle(
        fontSize: 10,
        fontFamily: 'monospace',
        fontWeight: bold ? FontWeight.w700 : FontWeight.w400,
        color: SaharaTheme.textSecondary,
      ),
    );
  }
}

/// ── Mode / Role Bar ────────────────────────────────────────────

/// Compact strip showing the active operation mode and device role.
///
/// Both are one tap away from changing, because they are the two settings a
/// person demonstrating the app on two phones needs to flip in a hurry.
class _ModeBar extends StatelessWidget {
  const _ModeBar({
    required this.settings,
    required this.handsFreeActive,
    required this.onToggleMode,
    required this.onOpenSettings,
  });

  final AppSettings settings;
  final bool handsFreeActive;
  final VoidCallback onToggleMode;
  final VoidCallback onOpenSettings;

  @override
  Widget build(BuildContext context) {
    final roleLabel = switch (settings.role) {
      AppRole.transceiver => 'Transceiver',
      AppRole.sttOnly => 'STT only',
      AppRole.ttsOnly => 'TTS only',
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      decoration: const BoxDecoration(
        color: SaharaTheme.surface,
        border: Border(bottom: BorderSide(color: SaharaTheme.border)),
      ),
      child: Row(
        children: [
          _MiniChip(
            icon: settings.isHandsFree ? Icons.hearing : Icons.touch_app,
            label: settings.isHandsFree ? 'PHONE / HANDS-FREE' : 'WALKIE-TALKIE',
            onTap: onToggleMode,
          ),
          if (handsFreeActive) ...[
            const SizedBox(width: 6),
            _MiniChip(
              icon: Icons.mic,
              label: 'LISTENING',
              color: SaharaTheme.success,
            ),
          ],
          const Spacer(),
          _MiniChip(
            icon: Icons.badge_outlined,
            label: roleLabel.toUpperCase(),
            onTap: onOpenSettings,
          ),
        ],
      ),
    );
  }
}

class _MiniChip extends StatelessWidget {
  const _MiniChip({
    required this.icon,
    required this.label,
    this.color,
    this.onTap,
  });

  final IconData icon;
  final String label;
  final Color? color;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = color ?? SaharaTheme.saffron;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
        decoration: BoxDecoration(
          color: c.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: c.withValues(alpha: 0.4)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 11, color: c),
            const SizedBox(width: 4),
            Text(
              label,
              style: TextStyle(
                fontSize: 9,
                fontWeight: FontWeight.w800,
                letterSpacing: 0.6,
                color: c,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// ── Talk Area ──────────────────────────────────────────────────

/// The centre control, which differs per role and per operation mode.
class _TalkArea extends StatelessWidget {
  const _TalkArea({
    required this.transceiverOn,
    required this.ctrl,
    required this.settings,
  });

  final bool transceiverOn;
  final TransceiverController ctrl;
  final AppSettings settings;

  @override
  Widget build(BuildContext context) {
    // Receiver-only role: there is no microphone, so show an explicit state
    // instead of a button that would silently do nothing.
    if (!settings.canTransmit) {
      return const _RolePlaceholder(
        icon: Icons.volume_up,
        title: 'TTS MODE — RECEIVER ONLY',
        detail: 'Waiting for incoming mesh packets.\nThe microphone is '
            'disabled in this role.',
      );
    }

    if (ctrl.handsFreeActive) {
      return _HandsFreePanel(
        interim: ctrl.interimText,
        paused: ctrl.isProcessing,
        onStop: () => ctrl.stopHandsFree(),
      );
    }

    return PttButton(
      isActive: transceiverOn && !ctrl.modelsDownloading,
      isRecording: ctrl.isRecording,
      isProcessing: ctrl.isProcessing,
      onPressed: () => ctrl.startPtt(),
      onReleased: () => ctrl.stopPtt(),
    );
  }
}

class _RolePlaceholder extends StatelessWidget {
  const _RolePlaceholder({
    required this.icon,
    required this.title,
    required this.detail,
  });

  final IconData icon;
  final String title;
  final String detail;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 24),
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: SaharaTheme.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: SaharaTheme.border),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 42, color: SaharaTheme.saffron),
          const SizedBox(height: 10),
          Text(
            title,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w800,
              letterSpacing: 1.2,
              color: SaharaTheme.saffron,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            detail,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 11,
              color: SaharaTheme.textMuted,
              height: 1.4,
            ),
          ),
        ],
      ),
    );
  }
}

/// Live view shown while hands-free listening is active.
class _HandsFreePanel extends StatelessWidget {
  const _HandsFreePanel({
    required this.interim,
    required this.paused,
    required this.onStop,
  });

  final String interim;
  final bool paused;
  final VoidCallback onStop;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 24),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: SaharaTheme.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: SaharaTheme.success.withValues(alpha: 0.45),
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.graphic_eq, size: 40, color: SaharaTheme.success),
          const SizedBox(height: 8),
          Text(
            paused ? 'TRANSMITTING…' : 'LISTENING — SPEAK FREELY',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w800,
              letterSpacing: 1.2,
              color: paused ? SaharaTheme.saffron : SaharaTheme.success,
            ),
          ),
          const SizedBox(height: 6),
          const Text(
            'A sentence is sent automatically after 3.0 s of silence.',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 11,
              color: SaharaTheme.textMuted,
            ),
          ),
          if (interim.isNotEmpty) ...[
            const SizedBox(height: 10),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: SaharaTheme.surfaceLight,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                interim,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 12,
                  color: SaharaTheme.textPrimary,
                ),
              ),
            ),
          ],
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: onStop,
            icon: const Icon(Icons.mic_off, size: 16),
            label: const Text('STOP LISTENING'),
            style: OutlinedButton.styleFrom(
              foregroundColor: SaharaTheme.textSecondary,
              side: const BorderSide(color: SaharaTheme.border),
            ),
          ),
        ],
      ),
    );
  }
}
