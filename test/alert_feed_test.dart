import 'package:flutter_test/flutter_test.dart';
import 'package:itantra/state/alert_feed.dart';

void main() {
  test('parses RSS items, strips HTML and decodes entities', () {
    const xml = '''
<rss version="2.0"><channel>
  <item>
    <title>Cyclone warning: &amp; coastal alert</title>
    <description><![CDATA[<p>Move to <b>higher ground</b> &amp; stay clear of the shore.</p>]]></description>
    <pubDate>2026-11-06T10:00:00Z</pubDate>
    <link>https://example.org/a/1</link>
  </item>
  <item>
    <title>Second alert</title>
    <description>Heavy rain expected.</description>
  </item>
</channel></rss>
''';
    final alerts = parseAlertFeed(xml, source: 'example.org');

    expect(alerts, hasLength(2));
    expect(alerts.first.title, 'Cyclone warning: & coastal alert');
    expect(alerts.first.body, 'Move to higher ground & stay clear of the shore.');
    expect(alerts.first.source, 'example.org');
    expect(alerts.first.published, DateTime.parse('2026-11-06T10:00:00Z'));
    expect(alerts.first.link, 'https://example.org/a/1');
    expect(alerts[1].published, isNull);
  });

  test('parses Atom entries with href links', () {
    const xml = '''
<feed xmlns="http://www.w3.org/2005/Atom">
  <entry>
    <title>Flood watch</title>
    <summary>River above danger level.</summary>
    <updated>2026-11-06T09:30:00Z</updated>
    <link rel="alternate" href="https://example.org/atom/2"/>
  </entry>
</feed>
''';
    final alerts = parseAlertFeed(xml, source: 'example.org');
    expect(alerts, hasLength(1));
    expect(alerts.first.title, 'Flood watch');
    expect(alerts.first.summaryText, 'Flood watch — River above danger level.');
    expect(alerts.first.link, 'https://example.org/atom/2');
  });

  test('deduplicates identical items within one feed', () {
    const xml = '''
<rss><channel>
  <item><title>Same</title><description>x</description></item>
  <item><title>Same</title><description>x</description></item>
</channel></rss>
''';
    expect(parseAlertFeed(xml), hasLength(1));
  });

  test('malformed or empty input yields no alerts instead of throwing', () {
    expect(parseAlertFeed('not xml at all'), isEmpty);
    expect(parseAlertFeed('<rss><channel></channel></rss>'), isEmpty);
  });

  test('numeric character references are decoded', () {
    const xml = '<rss><channel><item><title>A&#39;B &#x2014; C</title>'
        '<description>d</description></item></channel></rss>';
    final alerts = parseAlertFeed(xml);
    expect(alerts.single.title, "A'B — C");
  });
}
