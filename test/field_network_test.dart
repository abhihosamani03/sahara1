import 'package:flutter_test/flutter_test.dart';
import 'package:itantra/net/mesh_clock.dart';
import 'package:itantra/state/breadcrumb_trail.dart';

void main() {
  group('MeshClock', () {
    test('uses the median of peer samples', () {
      final local = DateTime.fromMillisecondsSinceEpoch(1000000);
      final clock = MeshClock(localNow: () => local);
      clock.observe(local.millisecondsSinceEpoch + 2000);
      clock.observe(local.millisecondsSinceEpoch + 2400);
      clock.observe(local.millisecondsSinceEpoch + 50000);
      expect(clock.offsetMs, 2400);
      expect(clock.synced, isTrue);
      expect(clock.now().millisecondsSinceEpoch, 1002400);
    });

    test('ignores an absurd peer clock', () {
      final local = DateTime.fromMillisecondsSinceEpoch(1000000);
      final clock = MeshClock(localNow: () => local);
      clock.observe(local.millisecondsSinceEpoch + 30 * 24 * 3600 * 1000);
      expect(clock.offsetMs, 0);
      expect(clock.synced, isFalse);
    });

    test('labels second and millisecond offsets', () {
      final local = DateTime.fromMillisecondsSinceEpoch(1000000);
      final clock = MeshClock(localNow: () => local);
      clock.observe(local.millisecondsSinceEpoch + 2500);
      expect(clock.label, '+2.5 s');
      final small = MeshClock(localNow: () => local);
      small.observe(local.millisecondsSinceEpoch - 180);
      expect(small.label, '−180 ms');
    });
  });

  group('BreadcrumbTrail', () {
    test('merges batches without duplicating timestamps', () {
      final trail = BreadcrumbTrail();
      const points = [
        BreadcrumbPoint(lat: 19.1, lon: 72.9, ts: 1000),
        BreadcrumbPoint(lat: 19.2, lon: 72.95, ts: 2000),
      ];
      expect(trail.merge('Asha', points), 2);
      expect(trail.merge('Asha', points), 0);
      expect(trail.forKey('Asha').length, 2);
    });

    test('round-trips the compact wire form', () {
      const points = [
        BreadcrumbPoint(lat: 19.076, lon: 72.8777, ts: 123456789),
        BreadcrumbPoint(lat: 19.08, lon: 72.88, ts: 123456999),
      ];
      final text = BreadcrumbTrail.encodeBatch(points);
      final decoded = BreadcrumbTrail.decodeBatch(text);
      expect(decoded.length, 2);
      expect(decoded.first.lat, closeTo(19.076, 1e-9));
      expect(decoded.last.ts, 123456999);
    });

    test('rejects malformed batches instead of throwing', () {
      expect(BreadcrumbTrail.decodeBatch('not json'), isEmpty);
      expect(BreadcrumbTrail.decodeBatch('{"p":[[999,999]]}'), isEmpty);
    });

    test('local fixes respect the movement/time gate', () {
      final trail = BreadcrumbTrail();
      expect(
        trail.addLocal(
          const BreadcrumbPoint(lat: 19.0, lon: 72.8, ts: 1000),
        ),
        isTrue,
      );
      // Same place a second later: not worth a transmission.
      expect(
        trail.addLocal(
          const BreadcrumbPoint(lat: 19.0, lon: 72.8, ts: 2000),
        ),
        isFalse,
      );
    });
  });
}
