import 'dart:convert';
import 'dart:io';

/// One early-warning item fetched from an RSS/Atom feed while online.
class FeedAlert {
  const FeedAlert({
    required this.id,
    required this.title,
    required this.body,
    required this.source,
    this.published,
    this.link,
  });

  final String id;
  final String title;
  final String body;
  final String source;
  final DateTime? published;
  final String? link;

  bool get isUsable => title.trim().isNotEmpty || body.trim().isNotEmpty;

  /// One sentence suitable for an `alert` packet and for speech.
  String get summaryText {
    final t = title.trim();
    final b = body.trim();
    if (t.isEmpty) return b;
    if (b.isEmpty) return t;
    return '$t — $b';
  }
}

/// Outcome of a refresh, including per-feed failures so the UI can say which
/// URL is broken instead of silently showing an empty list.
class AlertFeedResult {
  const AlertFeedResult({required this.alerts, required this.failures});

  final List<FeedAlert> alerts;
  final Map<String, String> failures;

  bool get hasFailures => failures.isNotEmpty;
  String get failureSummary => failures.entries
      .map((e) => '${Uri.tryParse(e.key)?.host ?? e.key}: ${e.value}')
      .join('\n');
}

/// Parses RSS 2.0 `<item>` and Atom `<entry>` blocks.
///
/// Deliberately a small, dependency-free scanner rather than a full XML
/// parser: the feeds that matter here are flat lists of title/description/
/// date, and a malformed feed must yield what it can instead of throwing.
List<FeedAlert> parseAlertFeed(String xml, {String source = '', Uri? baseUri}) {
  final alerts = <FeedAlert>[];
  final seen = <String>{};
  final blocks = RegExp(
    r'<(item|entry)\b[^>]*>([\s\S]*?)</\1>',
    caseSensitive: false,
  ).allMatches(xml);

  for (final match in blocks) {
    final block = match.group(2) ?? '';
    final title = _tagText(block, 'title') ?? '';
    final body = _tagText(block, 'description') ??
        _tagText(block, 'summary') ??
        _tagText(block, 'content') ??
        '';
    final dateRaw = _tagText(block, 'pubDate') ??
        _tagText(block, 'published') ??
        _tagText(block, 'updated');
    final linkRaw = _atomLink(block) ?? _tagText(block, 'link');
    final published = dateRaw == null ? null : DateTime.tryParse(dateRaw.trim());

    final id = _stableId('$source|${title.trim()}|$published|$linkRaw');
    if (!seen.add(id)) continue;

    final alert = FeedAlert(
      id: id,
      title: _clean(title),
      body: _clean(body),
      source: source,
      published: published,
      link: linkRaw,
    );
    if (alert.isUsable) alerts.add(alert);
  }
  return alerts;
}

/// Fetches and parses several feeds. One broken URL never blocks the others.
class AlertFeedFetcher {
  AlertFeedFetcher({
    HttpClient? client,
    this.timeout = const Duration(seconds: 8),
  }) : _client = client ?? HttpClient();

  final HttpClient _client;
  final Duration timeout;

  static const String _userAgent = 'Sahara/0.4 (early-warning feed reader)';

  Future<AlertFeedResult> fetchAll(List<String> urls) async {
    final alerts = <FeedAlert>[];
    final failures = <String, String>{};
    final seen = <String>{};

    for (final raw in urls) {
      final trimmed = raw.trim();
      if (trimmed.isEmpty) continue;
      final uri = Uri.tryParse(trimmed);
      if (uri == null || !uri.hasScheme || !uri.isScheme('http') && !uri.isScheme('https')) {
        failures[trimmed] = 'not an http(s) URL';
        continue;
      }
      try {
        _client.userAgent = _userAgent;
        _client.connectionTimeout = timeout;
        final request = await _client.getUrl(uri);
        request.headers.set(HttpHeaders.acceptHeader,
            'application/rss+xml, application/atom+xml, application/xml, text/xml, */*');
        final response = await request.close().timeout(timeout);
        if (response.statusCode != 200) {
          failures[trimmed] = 'HTTP ${response.statusCode}';
          await response.drain<void>();
          continue;
        }
        final body = await utf8
            .decoder
            .bind(response)
            .join()
            .timeout(timeout);
        for (final alert in parseAlertFeed(body, source: uri.host)) {
          if (seen.add(alert.id)) alerts.add(alert);
        }
      } catch (e) {
        failures[trimmed] = e.toString();
      }
    }

    alerts.sort((a, b) {
      final at = a.published, bt = b.published;
      if (at == null && bt == null) return 0;
      if (at == null) return 1;
      if (bt == null) return -1;
      return bt.compareTo(at);
    });
    return AlertFeedResult(alerts: alerts, failures: failures);
  }

  void close() => _client.close(force: true);
}

String? _tagText(String block, String tag) {
  final m = RegExp(
    '<$tag\\b[^>]*>([\\s\\S]*?)</$tag>',
    caseSensitive: false,
  ).firstMatch(block);
  if (m == null) return null;
  return _unwrapCdata(m.group(1) ?? '').trim();
}

String? _atomLink(String block) {
  final tagged = RegExp(
    r'<link\b[^>]*>([\s\S]*?)</link>',
    caseSensitive: false,
  ).firstMatch(block);
  if (tagged != null) {
    final text = _unwrapCdata(tagged.group(1) ?? '').trim();
    if (text.isNotEmpty) return text;
  }
  final m = RegExp(
    r'''<link\b[^>]*href\s*=\s*["']([^"']+)["']''',
    caseSensitive: false,
  ).firstMatch(block);
  return m?.group(1);
}

String _unwrapCdata(String value) {
  final m = RegExp(r'<!\[CDATA\[([\s\S]*?)\]\]>').firstMatch(value);
  return m?.group(1) ?? value;
}

/// Strip markup, decode the common entities, collapse whitespace.
String _clean(String value) {
  var text = _unwrapCdata(value);
  text = text.replaceAll(RegExp(r'<[^>]*>'), ' ');
  text = text
      .replaceAll('&nbsp;', ' ')
      .replaceAll('&amp;', '&')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .replaceAll('&apos;', "'");
  text = text.replaceAllMapped(
    RegExp(r'&#(x?)([0-9a-fA-F]+);'),
    (m) {
      final code = int.tryParse(
        m.group(2)!,
        radix: m.group(1)!.isEmpty ? 10 : 16,
      );
      return code == null ? '' : String.fromCharCode(code);
    },
  );
  return text.replaceAll(RegExp(r'\s+'), ' ').trim();
}

/// FNV-1a over the identifying fields — stable across runs, no crypto needed.
String _stableId(String input) {
  var hash = 0x811C9DC5;
  for (final byte in utf8.encode(input)) {
    hash ^= byte;
    hash = (hash * 0x01000193) & 0xFFFFFFFF;
  }
  return hash.toRadixString(16).padLeft(8, '0');
}
