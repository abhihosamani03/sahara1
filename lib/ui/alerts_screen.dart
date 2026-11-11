import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/theme.dart';
import '../state/alert_feed.dart';
import '../state/app_settings.dart';
import '../state/transceiver_controller.dart';

/// Early-warning inbox: pull RSS/Atom alerts while a connection exists, then
/// rebroadcast one over the mesh so it reaches phones with no internet at all.
class AlertsScreen extends StatefulWidget {
  const AlertsScreen({super.key});

  @override
  State<AlertsScreen> createState() => _AlertsScreenState();
}

class _AlertsScreenState extends State<AlertsScreen> {
  bool _busy = false;

  Future<void> _refresh(TransceiverController ctrl) async {
    if (_busy) return;
    setState(() => _busy = true);
    final ok = await ctrl.refreshAlerts();
    if (!mounted) return;
    setState(() => _busy = false);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(ok
          ? '${ctrl.alerts.length} alert${ctrl.alerts.length == 1 ? '' : 's'} loaded'
          : 'Refresh failed — check the feed URLs'),
    ));
  }

  Future<void> _editFeeds(AppSettings settings) async {
    final controller = TextEditingController(
      text: settings.alertFeeds.join('\n'),
    );
    final saved = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Alert feed URLs'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'One RSS or Atom URL per line. They are only read when you tap '
              'refresh — nothing is fetched in the background.',
              style: TextStyle(fontSize: 12, color: SaharaTheme.textMuted),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              maxLines: 5,
              decoration: const InputDecoration(
                hintText: 'https://example.org/alerts.rss',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (saved == null) return;
    settings.alertFeeds = saved
        .split('\n')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    final ctrl = context.watch<TransceiverController>();
    final settings = context.watch<AppSettings>();
    final alerts = ctrl.alerts;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Early warning'),
        actions: [
          IconButton(
            tooltip: 'Feed URLs',
            icon: const Icon(Icons.rss_feed, size: 20),
            onPressed: () => _editFeeds(settings),
          ),
          IconButton(
            tooltip: 'Refresh feeds',
            icon: _busy
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.refresh, size: 20),
            onPressed: _busy ? null : () => _refresh(ctrl),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _busy ? null : () => _refresh(ctrl),
        icon: const Icon(Icons.cloud_download_outlined),
        label: const Text('Fetch alerts'),
      ),
      body: settings.alertFeeds.isEmpty
          ? _Empty(
              title: 'No feeds configured',
              body: 'Add an RSS or Atom feed (for example a district '
                  'administration or weather-warning feed) with the '
                  '\u{1F4E1} button. Alerts are cached here and can then be '
                  'broadcast over the mesh with no internet.',
              action: 'Add feed URL',
              onAction: () => _editFeeds(settings),
            )
          : alerts.isEmpty
              ? _Empty(
                  title: ctrl.alertsLoading ? 'Fetching…' : 'No alerts yet',
                  body: 'Tap Fetch alerts while connected. Each item can then '
                      'be sent to every phone in range as a warning packet.',
                  action: 'Fetch now',
                  onAction: () => _refresh(ctrl),
                )
              : ListView.separated(
                  padding: const EdgeInsets.fromLTRB(12, 12, 12, 96),
                  itemCount: alerts.length + (ctrl.alertFeedError == null ? 0 : 1),
                  separatorBuilder: (_, _) => const SizedBox(height: 8),
                  itemBuilder: (context, index) {
                    if (index == alerts.length) {
                      return _FeedError(text: ctrl.alertFeedError!);
                    }
                    return _AlertCard(
                      alert: alerts[index],
                      onBroadcast: () async {
                        final ok = await ctrl.broadcastAlert(alerts[index]);
                        if (!context.mounted) return;
                        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                          content: Text(ok
                              ? 'Warning broadcast over the mesh'
                              : 'No peer in range — warning queued'),
                        ));
                      },
                    );
                  },
                ),
    );
  }
}

class _AlertCard extends StatelessWidget {
  const _AlertCard({required this.alert, required this.onBroadcast});

  final FeedAlert alert;
  final VoidCallback onBroadcast;

  @override
  Widget build(BuildContext context) {
    final when = alert.published;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              alert.title,
              style: const TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w700,
                color: SaharaTheme.textPrimary,
              ),
            ),
            if (alert.body.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                alert.body,
                maxLines: 4,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 12,
                  color: SaharaTheme.textSecondary,
                ),
              ),
            ],
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: Text(
                    [
                      if (alert.source.isNotEmpty) alert.source,
                      if (when != null) _time(when),
                    ].join(' · '),
                    style: const TextStyle(
                      fontSize: 10,
                      color: SaharaTheme.textMuted,
                    ),
                  ),
                ),
                TextButton.icon(
                  onPressed: onBroadcast,
                  icon: const Icon(Icons.campaign_outlined, size: 16),
                  label: const Text('Broadcast'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  static String _time(DateTime t) =>
      '${t.day}/${t.month} ${t.hour.toString().padLeft(2, '0')}:'
      '${t.minute.toString().padLeft(2, '0')}';
}

class _FeedError extends StatelessWidget {
  const _FeedError({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: SaharaTheme.danger.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(
          'Some feeds failed:\n$text',
          style: const TextStyle(fontSize: 11, color: SaharaTheme.danger),
        ),
      );
}

class _Empty extends StatelessWidget {
  const _Empty({
    required this.title,
    required this.body,
    required this.action,
    required this.onAction,
  });

  final String title;
  final String body;
  final String action;
  final VoidCallback onAction;

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.warning_amber_rounded,
                  size: 36, color: SaharaTheme.saffron),
              const SizedBox(height: 12),
              Text(
                title,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: SaharaTheme.textPrimary,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                body,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 12,
                  color: SaharaTheme.textMuted,
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 16),
              FilledButton(onPressed: onAction, child: Text(action)),
            ],
          ),
        ),
      );
}
