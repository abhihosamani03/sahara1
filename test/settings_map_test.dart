import 'dart:convert' show utf8;

import 'package:flutter_test/flutter_test.dart';
import 'package:itantra/ml/ibfs.dart' show kMaxSenderNameChars;
import 'package:itantra/state/app_settings.dart';
import 'package:itantra/ui/widgets/offline_map.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    // shared_preferences has no platform channel in a unit test; this installs
    // the in-memory implementation so persistence calls resolve.
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  group('AppSettings', () {
    test('defaults are sane for a first launch', () {
      final s = AppSettings();
      expect(s.username, '');
      expect(s.speechRate, 1.0);
      expect(s.silentSosEnabled, isTrue);
      expect(s.translationEnabled, isTrue);
      expect(s.operationMode, OperationMode.walkieTalkie);
      expect(s.role, AppRole.transceiver);
      expect(s.gpsEnabled, isTrue);
      expect(s.hasMedicalInfo, isFalse);
      expect(s.medicalSummary, isNull);
    });

    test('username is clamped to the wire limit', () {
      final s = AppSettings();
      s.username = 'AVeryLongNameIndeed';
      expect(s.username.length, kMaxSenderNameChars);
      expect(s.username, 'AVeryLon');
    });

    test('username keeps a multi-byte name intact', () {
      final s = AppSettings();
      // Exactly 8 Devanagari code points, 24 bytes — the clamp is by character,
      // so this must survive untouched even though it is 24 bytes on the wire.
      const name = 'विकासराज';
      expect(name.runes.length, kMaxSenderNameChars);
      expect(utf8.encode(name).length, 24);
      s.username = name;
      expect(s.username, name);
    });

    test('username clamps by character, not by byte', () {
      final s = AppSettings();
      s.username = 'विकासराजु'; // 9 code points
      expect(s.username.runes.length, kMaxSenderNameChars);
      expect(s.username, 'विकासराज');
    });

    test('username strips control characters', () {
      final s = AppSettings();
      s.username = 'Vi\nka\ts\u0007';
      expect(s.username, 'Vikas');
    });

    test('username trims surrounding whitespace', () {
      final s = AppSettings();
      s.username = '   Ravi   ';
      expect(s.username, 'Ravi');
    });

    test('speech rate is clamped to the supported range', () {
      final s = AppSettings();
      s.speechRate = 9.0;
      expect(s.speechRate, AppSettings.maxSpeechRate);
      s.speechRate = 0.01;
      expect(s.speechRate, AppSettings.minSpeechRate);
      // A NaN rate would make the synthesizer produce silence; fall back to
      // normal speed rather than to a clamped extreme.
      s.speechRate = double.nan;
      expect(s.speechRate, 1.0);
      s.speechRate = 1.25;
      expect(s.speechRate, 1.25);
    });

    test('role and mode helpers drive feature gating', () {
      final s = AppSettings();

      s.role = AppRole.sttOnly;
      expect(s.canTransmit, isTrue);
      expect(s.canReceive, isFalse);

      s.role = AppRole.ttsOnly;
      expect(s.canTransmit, isFalse);
      expect(s.canReceive, isTrue);

      s.role = AppRole.transceiver;
      expect(s.canTransmit, isTrue);
      expect(s.canReceive, isTrue);

      s.operationMode = OperationMode.phone;
      expect(s.isHandsFree, isTrue);
      s.operationMode = OperationMode.walkieTalkie;
      expect(s.isHandsFree, isFalse);
    });

    test('medical summary is built from whatever is filled in', () {
      final s = AppSettings();
      s.bloodGroup = 'O+';
      expect(s.medicalSummary, 'Blood O+');

      s.conditions = 'asthma';
      s.emergencyContacts = '98765 43210';
      expect(s.medicalSummary, 'Blood O+ · asthma · Contact 98765 43210');
      expect(s.hasMedicalInfo, isTrue);

      s.clearMedicalInfo();
      expect(s.medicalSummary, isNull);
    });

    test('values persist and reload', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'set.username': 'Asha',
        'set.speechRate': 1.35,
        'set.silentSos': false,
        'set.translation': false,
        'set.bloodGroup': 'B+',
        'set.conditions': 'diabetic',
        'set.emergencyContacts': '112',
        'set.operationMode': 'phone',
        'set.role': 'ttsOnly',
        'set.gpsEnabled': false,
      });

      final s = AppSettings();
      await s.load();

      expect(s.username, 'Asha');
      expect(s.speechRate, 1.35);
      expect(s.silentSosEnabled, isFalse);
      expect(s.translationEnabled, isFalse);
      expect(s.bloodGroup, 'B+');
      expect(s.conditions, 'diabetic');
      expect(s.emergencyContacts, '112');
      expect(s.operationMode, OperationMode.phone);
      expect(s.role, AppRole.ttsOnly);
      expect(s.gpsEnabled, isFalse);
    });

    test('an unknown stored enum name falls back to the default', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'set.role': 'fromAFutureBuild',
        'set.operationMode': 'telepathy',
      });
      final s = AppSettings();
      await s.load();
      expect(s.role, AppRole.transceiver);
      expect(s.operationMode, OperationMode.walkieTalkie);
    });

    test('a corrupt stored username is sanitised on load', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'set.username': 'SomeoneWithAVeryLongName',
      });
      final s = AppSettings();
      await s.load();
      expect(s.username.length, kMaxSenderNameChars);
    });

    test('listeners fire on change', () {
      final s = AppSettings();
      var calls = 0;
      s.addListener(() => calls++);
      s.username = 'Ravi';
      s.speechRate = 1.2;
      // Setting the same value again must not notify.
      s.username = 'Ravi';
      expect(calls, 2);
    });
  });

  group('MercatorProjection', () {
    test('zoom 0 is a single 256 px tile', () {
      expect(MercatorProjection.worldSize(0), 256.0);
      expect(MercatorProjection.worldSize(1), 512.0);
      expect(MercatorProjection.worldSize(10), 256.0 * 1024);
    });

    test('prime meridian and equator meet at the centre', () {
      expect(MercatorProjection.xForLon(0, 0), closeTo(128, 0.0001));
      expect(MercatorProjection.yForLat(0, 0), closeTo(128, 0.0001));
    });

    test('longitude spans the world left to right', () {
      expect(MercatorProjection.xForLon(-180, 4), closeTo(0, 0.0001));
      expect(MercatorProjection.xForLon(180, 4),
          closeTo(MercatorProjection.worldSize(4), 0.0001));
      expect(MercatorProjection.xForLon(0, 4),
          closeTo(MercatorProjection.worldSize(4) / 2, 0.0001));
    });

    test('North sits above South, as on screen', () {
      expect(MercatorProjection.yForLat(30, 8),
          lessThan(MercatorProjection.yForLat(20, 8)));
      expect(MercatorProjection.yForLat(0, 8),
          lessThan(MercatorProjection.yForLat(-20, 8)));
    });

    test('latitude is clamped to the projection limit', () {
      // Beyond ~85.05° the Mercator y would run off the world; clamping keeps
      // a bad GPS fix from producing a NaN or an off-map marker.
      final top = MercatorProjection.yForLat(89.9, 4);
      expect(top.isFinite, isTrue);
      expect(top, greaterThanOrEqualTo(0));
      expect(top, closeTo(0, 1.0));
    });

    test('longitude and latitude round-trip through pixel space', () {
      for (final lat in [-80.0, -40.0, 0.0, 12.9716, 40.0, 80.0]) {
        for (final lon in [-179.0, -75.5, 0.0, 77.5946, 179.0]) {
          const zoom = 12;
          final x = MercatorProjection.xForLon(lon, zoom);
          final y = MercatorProjection.yForLat(lat, zoom);
          expect(MercatorProjection.lonForX(x, zoom), closeTo(lon, 1e-6),
              reason: 'lon $lon failed at zoom $zoom');
          expect(MercatorProjection.latForY(y, zoom), closeTo(lat, 1e-6),
              reason: 'lat $lat failed at zoom $zoom');
        }
      }
    });

    test('a coordinate falls inside the tile that contains it', () {
      // The property that actually matters: sibling tiles must line up, or the
      // map shows seams and the marker lands in the wrong square.
      const zoom = 10;
      const lat = 12.9716; // Bengaluru
      const lon = 77.5946;
      const ts = MercatorProjection.tileSize;

      final tileX = (MercatorProjection.xForLon(lon, zoom) / ts).floor();
      final tileY = (MercatorProjection.yForLat(lat, zoom) / ts).floor();

      final west = MercatorProjection.lonForX(tileX * ts, zoom);
      final east = MercatorProjection.lonForX((tileX + 1) * ts, zoom);
      final north = MercatorProjection.latForY(tileY * ts, zoom);
      final south = MercatorProjection.latForY((tileY + 1) * ts, zoom);

      expect(lon, greaterThanOrEqualTo(west));
      expect(lon, lessThanOrEqualTo(east));
      expect(lat, lessThanOrEqualTo(north));
      expect(lat, greaterThanOrEqualTo(south));
    });
  });
}
