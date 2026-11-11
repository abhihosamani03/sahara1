import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../core/theme.dart';
import '../ml/ibfs.dart' show kMaxSenderNameChars;
import '../net/mbtiles_import.dart';
import '../state/app_settings.dart';
import '../state/transceiver_controller.dart';
import 'incident_map_screen.dart';

/// Settings screen.
///
/// Every value here is persisted through [AppSettings] (SharedPreferences), so
/// it survives a restart — including a restart triggered by the OS while the
/// app is running as a background standby service.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late final TextEditingController _name;
  late final TextEditingController _blood;
  late final TextEditingController _conditions;
  late final TextEditingController _contacts;

  @override
  void initState() {
    super.initState();
    final s = context.read<AppSettings>();
    _name = TextEditingController(text: s.username);
    _blood = TextEditingController(text: s.bloodGroup);
    _conditions = TextEditingController(text: s.conditions);
    _contacts = TextEditingController(text: s.emergencyContacts);
  }

  @override
  void dispose() {
    _name.dispose();
    _blood.dispose();
    _conditions.dispose();
    _contacts.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<AppSettings>();
    final ctrl = context.watch<TransceiverController>();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.of(context).maybePop(),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        children: [
          // ── Identity ──────────────────────────────────────────
          _Section(
            title: 'Identity',
            subtitle: 'Transmitted with every message so receivers know '
                'who is speaking.',
            children: [
              TextField(
                controller: _name,
                maxLength: kMaxSenderNameChars,
                textCapitalization: TextCapitalization.words,
                inputFormatters: [
                  LengthLimitingTextInputFormatter(kMaxSenderNameChars),
                  FilteringTextInputFormatter.deny(RegExp(r'[\n\r\t]')),
                ],
                style: const TextStyle(
                  fontSize: 14,
                  color: SaharaTheme.textPrimary,
                ),
                decoration: _fieldDecoration(
                  label: 'Username',
                  hint: 'e.g. Vikas',
                  counter: '${_name.text.runes.length}/'
                      '$kMaxSenderNameChars · short names save packet space',
                ),
                onChanged: (v) {
                  settings.username = v;
                  setState(() {});
                },
              ),
              const SizedBox(height: 4),
              Text(
                settings.username.isEmpty
                    ? 'Not set — receivers will see messages without a name.'
                    : 'Receivers will see "[${settings.username}] …"',
                style: TextStyle(
                  fontSize: 11,
                  color: settings.username.isEmpty
                      ? SaharaTheme.textMuted
                      : SaharaTheme.success,
                ),
              ),
            ],
          ),

          // ── Operation mode & role ─────────────────────────────
          _Section(
            title: 'Operation mode',
            subtitle: 'How the microphone is driven.',
            children: [
              _ChoiceRow<OperationMode>(
                value: settings.operationMode,
                options: const {
                  OperationMode.walkieTalkie: 'Walkie-Talkie (PTT)',
                  OperationMode.phone: 'Phone (hands-free)',
                },
                onChanged: (m) => settings.operationMode = m,
              ),
              const SizedBox(height: 8),
              Text(
                settings.isHandsFree
                    ? 'Hands-free: the mic stays open. Silero VAD closes a '
                        'sentence after 3.0 s of silence and sends it with no '
                        'button press.'
                    : 'Push-to-talk: hold the button to speak, release to send. '
                        'A quick tap latches recording until the next tap.',
                style: const TextStyle(
                  fontSize: 11,
                  color: SaharaTheme.textSecondary,
                  height: 1.35,
                ),
              ),
            ],
          ),

          _Section(
            title: 'Device role',
            subtitle: 'For a two-phone evaluation: set one phone to STT Mode '
                'and the other to TTS Mode to verify the full loop.',
            children: [
              _ChoiceRow<AppRole>(
                value: settings.role,
                options: const {
                  AppRole.transceiver: 'Transceiver',
                  AppRole.sttOnly: 'STT (sender)',
                  AppRole.ttsOnly: 'TTS (receiver)',
                },
                onChanged: (r) => settings.role = r,
              ),
              const SizedBox(height: 8),
              _RoleExplainer(role: settings.role),
            ],
          ),

          // ── Audio ─────────────────────────────────────────────
          _Section(
            title: 'Audio',
            subtitle: 'Playback speed for both the neural and platform voices.',
            children: [
              Row(
                children: [
                  const Icon(Icons.speed, size: 18,
                      color: SaharaTheme.saffron),
                  const SizedBox(width: 8),
                  Text(
                    '${settings.speechRate.toStringAsFixed(2)}×',
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: SaharaTheme.textPrimary,
                    ),
                  ),
                ],
              ),
              Slider(
                value: settings.speechRate,
                min: AppSettings.minSpeechRate,
                max: AppSettings.maxSpeechRate,
                divisions: 20,
                activeColor: SaharaTheme.saffron,
                inactiveColor: SaharaTheme.surfaceLight,
                onChanged: (v) => settings.speechRate = v,
              ),
              const Text(
                'Lower it if the neural voice sounds rushed, raise it if '
                'the voice is too slow to follow.',
                style: TextStyle(
                  fontSize: 11,
                  color: SaharaTheme.textMuted,
                ),
              ),
            ],
          ),

          // ── Translation ───────────────────────────────────────
          _Section(
            title: 'Translation',
            subtitle: 'On-device translation runs between decode and speech. '
                'Models download once (~30 MB per language) and then work '
                'with no network at all.',
            children: [
              _SwitchRow(
                title: 'Translate incoming messages',
                subtitle: 'Off: an incoming message is spoken in the sender\'s '
                    'language. On: it is spoken in your receiver language when '
                    'that pair\'s model is already on the device; otherwise it '
                    'falls back to the original with a note.',
                value: settings.translationEnabled,
                onChanged: (v) => settings.translationEnabled = v,
              ),
              const SizedBox(height: 8),
              const Text(
                'ML Kit has no model for Malayalam, Odia, Punjabi, Assamese, '
                'Nepali or the north-eastern languages. Those pairs always '
                'show and speak the original text.',
                style: TextStyle(
                  fontSize: 11,
                  color: SaharaTheme.textSecondary,
                  height: 1.35,
                ),
              ),
            ],
          ),

          // ── Emergency ─────────────────────────────────────────
          _Section(
            title: 'Emergency',
            subtitle: 'Pre-set telemetry is appended to every SOS you send.',
            children: [
              _SwitchRow(
                title: 'Hardware SOS trigger',
                subtitle: 'Hold a volume key to fire an SOS without looking '
                    'at the screen. Works while Sahara is running, including '
                    'in the background.',
                value: settings.silentSosEnabled,
                onChanged: (v) => settings.silentSosEnabled = v,
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _blood,
                style: const TextStyle(
                  fontSize: 14,
                  color: SaharaTheme.textPrimary,
                ),
                decoration: _fieldDecoration(
                  label: 'Blood group',
                  hint: 'e.g. O+',
                ),
                onChanged: (v) => settings.bloodGroup = v,
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _conditions,
                maxLines: 2,
                style: const TextStyle(
                  fontSize: 14,
                  color: SaharaTheme.textPrimary,
                ),
                decoration: _fieldDecoration(
                  label: 'Pre-existing conditions',
                  hint: 'e.g. asthma, diabetic',
                ),
                onChanged: (v) => settings.conditions = v,
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _contacts,
                style: const TextStyle(
                  fontSize: 14,
                  color: SaharaTheme.textPrimary,
                ),
                decoration: _fieldDecoration(
                  label: 'Emergency contact',
                  hint: 'e.g. 98765 43210',
                ),
                onChanged: (v) => settings.emergencyContacts = v,
              ),
              const SizedBox(height: 10),
              _EmergencyStatus(ctrl: ctrl),
            ],
          ),

          // ── Field network ────────────────────────────────────
          _Section(
            title: 'Field network',
            subtitle: 'Mesh routing, relay duty and offline map packs.',
            children: [
              _SwitchRow(
                title: 'Relay-only mode',
                subtitle: 'This phone carries other people\'s traffic and '
                    'does no speech recognition or playback. BLE advertising '
                    'stays on, Wi-Fi Direct is switched off, and the radio '
                    'scans less often to save battery.',
                value: settings.relayMode,
                onChanged: (v) => settings.relayMode = v,
              ),
              const SizedBox(height: 10),
              _SwitchRow(
                title: 'Start on boot',
                subtitle: 'Reopen emergency standby and the mesh after the '
                    'phone restarts. Needs standby/DND/battery access to work '
                    'reliably on aggressive OEM builds.',
                value: settings.startOnBoot,
                onChanged: (v) => settings.startOnBoot = v,
              ),
              const SizedBox(height: 10),
              _SwitchRow(
                title: 'Share breadcrumb trail',
                subtitle: 'Record a GPS fix every 30 s (only when you have '
                    'moved) and gossip the last 20 points. Responders see '
                    'covered ground on the incident map.',
                value: settings.breadcrumbsEnabled,
                onChanged: (v) => settings.breadcrumbsEnabled = v,
              ),
              const SizedBox(height: 10),
              _SwitchRow(
                title: 'Live voice (Codec2)',
                subtitle: 'Push-to-talk sends real-time audio at 3200 bps '
                    'instead of transcribing it. Works on a phone with no '
                    'speech model downloaded, and is understood on the radio '
                    'even when recognition would fail in the noise.',
                value: settings.liveVoiceEnabled,
                onChanged: (v) => settings.liveVoiceEnabled = v,
              ),
              const SizedBox(height: 10),
              _ActionRow(
                icon: Icons.map_outlined,
                label: 'Open incident map',
                detail: 'Every positioned SOS, need and warning plus all '
                    'breadcrumb trails, over the offline tile store.',
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const IncidentMapScreen(),
                  ),
                ),
              ),
              _ActionRow(
                icon: Icons.add_location_alt_outlined,
                label: 'Import offline map region (.mbtiles)',
                detail: 'Adds a whole region pack to the offline map. '
                    'Up to ${MbtilesImporter.maxTiles} tiles per import; '
                    'existing tiles are kept.',
                onTap: () => _importMbtiles(context),
              ),
              const SizedBox(height: 6),
              Row(
                children: [
                  const Icon(Icons.sync_alt, size: 14,
                      color: SaharaTheme.textMuted),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      'Mesh clock ${ctrl.meshClockLabel} · '
                      '${ctrl.routeCount} learned route'
                      '${ctrl.routeCount == 1 ? '' : 's'}',
                      style: const TextStyle(
                        fontSize: 10,
                        color: SaharaTheme.textMuted,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),

          // ── Storage ───────────────────────────────────────────
          _Section(
            title: 'Storage & rescue log',
            subtitle: 'Downloaded AI models are kept — re-downloading a '
                '150 MB speech model offline is not possible.',
            children: [
              _ActionRow(
                icon: Icons.cleaning_services,
                label: 'Clear cached audio & message log',
                detail: 'Removes cached speech clips, the packet log and any '
                    'undelivered queued messages.',
                onTap: () => _clear(context, ctrl, const {}),
              ),
              _ActionRow(
                icon: Icons.memory,
                label: 'Delete downloaded speech models',
                detail: 'Last resort. Speech and voice models re-download on '
                    'next use — only do this if you are low on storage and '
                    'have connectivity.',
                onTap: () => _confirmDeleteSpeechModels(context, ctrl),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _importMbtiles(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    FilePickerResult? picked;
    try {
      picked = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['mbtiles'],
        withData: false,
      );
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('File picker unavailable: $e')),
      );
      return;
    }
    if (picked == null) return;
    final path = picked.files.single.path;
    if (path == null) {
      messenger.showSnackBar(
        const SnackBar(content: Text('Could not read the selected file')),
      );
      return;
    }

    messenger.showSnackBar(const SnackBar(
      content: Text('Importing map tiles — this can take a minute…'),
      duration: Duration(seconds: 4),
    ));
    final result = await MbtilesImporter.importFile(path);
    if (!mounted) return;
    messenger.showSnackBar(SnackBar(
      content: Text(result.ok
          ? '${result.message} — available offline'
          : result.message),
      duration: const Duration(seconds: 5),
    ));
  }

  Future<void> _confirmDeleteSpeechModels(
    BuildContext context,
    TransceiverController ctrl,
  ) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: SaharaTheme.surface,
        title: const Text('Delete speech models?'),
        content: const Text(
          'The offline speech-recognition and neural voice models will be '
          'deleted. Until they are downloaded again, transcription falls back '
          'to nothing and the voice falls back to the phone synthesizer.',
          style: TextStyle(fontSize: 13, height: 1.4),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('CANCEL'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: ElevatedButton.styleFrom(
              backgroundColor: SaharaTheme.danger,
              foregroundColor: Colors.white,
            ),
            child: const Text('DELETE'),
          ),
        ],
      ),
    );
    if (ok == true && context.mounted) {
      await _clear(
        context,
        ctrl,
        const {_ClearOption.speechModels},
      );
    }
  }

  Future<void> _clear(
    BuildContext context,
    TransceiverController ctrl,
    Set<_ClearOption> options,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    final report = await ctrl.clearCaches(
      dropTranslationModels:
          options.contains(_ClearOption.translationModels),
      dropSpeechModels: options.contains(_ClearOption.speechModels),
    );
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          report.clipCount == 0 && report.logEntries == 0
              ? 'Nothing to clear'
              : 'Cleared ${report.clipCount} cached '
                  'clip${report.clipCount == 1 ? '' : 's'} '
                  '(${report.prettySize}) and ${report.logEntries} '
                  'log entr${report.logEntries == 1 ? 'y' : 'ies'}',
        ),
        duration: const Duration(seconds: 3),
      ),
    );
  }
}

enum _ClearOption { translationModels, speechModels }

// ── Building blocks ──────────────────────────────────────────────

InputDecoration _fieldDecoration({
  required String label,
  String? hint,
  String? counter,
}) {
  return InputDecoration(
    labelText: label,
    hintText: hint,
    counterText: counter,
    labelStyle: const TextStyle(fontSize: 13, color: SaharaTheme.textSecondary),
    hintStyle: const TextStyle(fontSize: 13, color: SaharaTheme.textMuted),
    counterStyle: const TextStyle(fontSize: 10, color: SaharaTheme.textMuted),
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
      borderSide: const BorderSide(color: SaharaTheme.saffron),
    ),
  );
}

class _Section extends StatelessWidget {
  const _Section({
    required this.title,
    required this.children,
    this.subtitle,
  });

  final String title;
  final String? subtitle;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: SaharaTheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: SaharaTheme.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title.toUpperCase(),
            style: const TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w800,
              letterSpacing: 1.2,
              color: SaharaTheme.saffron,
            ),
          ),
          if (subtitle != null) ...[
            const SizedBox(height: 4),
            Text(
              subtitle!,
              style: const TextStyle(
                fontSize: 11,
                color: SaharaTheme.textMuted,
                height: 1.35,
              ),
            ),
          ],
          const SizedBox(height: 12),
          ...children,
        ],
      ),
    );
  }
}

/// Segmented choice row. Hand-built rather than [SegmentedButton] so it
/// matches the existing dark theme exactly.
class _ChoiceRow<T> extends StatelessWidget {
  const _ChoiceRow({
    required this.value,
    required this.options,
    required this.onChanged,
  });

  final T value;
  final Map<T, String> options;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: options.entries.map((e) {
        final selected = e.key == value;
        return Expanded(
          child: Padding(
            padding: const EdgeInsets.only(right: 6),
            child: InkWell(
              onTap: () => onChanged(e.key),
              borderRadius: BorderRadius.circular(8),
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 9),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: selected
                      ? SaharaTheme.saffron.withValues(alpha: 0.18)
                      : SaharaTheme.surfaceLight,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: selected
                        ? SaharaTheme.saffron
                        : SaharaTheme.border,
                  ),
                ),
                child: Text(
                  e.value,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: selected
                        ? SaharaTheme.saffron
                        : SaharaTheme.textSecondary,
                  ),
                ),
              ),
            ),
          ),
        );
      }).toList(),
    );
  }
}

class _SwitchRow extends StatelessWidget {
  const _SwitchRow({
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
  });

  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: SaharaTheme.textPrimary,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                subtitle,
                style: const TextStyle(
                  fontSize: 11,
                  color: SaharaTheme.textMuted,
                  height: 1.3,
                ),
              ),
            ],
          ),
        ),
        Switch(
          value: value,
          onChanged: onChanged,
          activeThumbColor: SaharaTheme.saffron,
        ),
      ],
    );
  }
}

class _ActionRow extends StatelessWidget {
  const _ActionRow({
    required this.icon,
    required this.label,
    required this.detail,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final String detail;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 18, color: SaharaTheme.saffron),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: SaharaTheme.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    detail,
                    style: const TextStyle(
                      fontSize: 11,
                      color: SaharaTheme.textMuted,
                      height: 1.3,
                    ),
                  ),
                ],
              ),
            ),
            const Icon(Icons.chevron_right,
                size: 18, color: SaharaTheme.textMuted),
          ],
        ),
      ),
    );
  }
}

class _RoleExplainer extends StatelessWidget {
  const _RoleExplainer({required this.role});
  final AppRole role;

  @override
  Widget build(BuildContext context) {
    final text = switch (role) {
      AppRole.transceiver =>
        'Sends and receives. The normal operating mode.',
      AppRole.sttOnly =>
        'Sender only: microphone, live transcript and latency benchmarks '
            '(STT ms, RTF). Incoming audio is logged but never played.',
      AppRole.ttsOnly =>
        'Receiver only: mesh reception and loud voice playback. '
            'The microphone is disabled.',
    };
    return Text(
      text,
      style: const TextStyle(
        fontSize: 11,
        color: SaharaTheme.textSecondary,
        height: 1.35,
      ),
    );
  }
}

class _EmergencyStatus extends StatelessWidget {
  const _EmergencyStatus({required this.ctrl});
  final TransceiverController ctrl;

  @override
  Widget build(BuildContext context) {
    Widget chip(String label, bool ok, VoidCallback? onTap) {
      final color = ok ? SaharaTheme.success : SaharaTheme.saffron;
      return InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: color.withValues(alpha: 0.4)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(ok ? Icons.check_circle : Icons.error_outline,
                  size: 12, color: color),
              const SizedBox(width: 4),
              Text(
                label,
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                  color: color,
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        chip('Standby', ctrl.standbyActive, ctrl.openBatterySettings),
        chip('DND access', ctrl.dndAccess, ctrl.openDndSettings),
        chip('Battery exempt', ctrl.batteryExempt, ctrl.openBatterySettings),
      ],
    );
  }
}
