import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:itantra/ml/ibfs.dart';
import 'package:itantra/ml/languages.dart';
import 'package:itantra/state/incident.dart';
import 'package:shared_preferences/shared_preferences.dart';

IbfPacket _packet({
  required PacketType type,
  required String text,
  Priority priority = Priority.routine,
  int seq = 1,
  double? lat,
  double? lon,
  String? sender = 'Asha',
}) =>
    IbfPacket(
      type: type,
      priority: priority,
      language: kEnglish,
      sequenceId: seq,
      text: text,
      latitude: lat,
      longitude: lon,
      senderName: sender,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('Structured packet types', () {
    test('every new type survives encode/decode and is marked structured', () {
      for (final type in [
        PacketType.statusReport,
        PacketType.checkIn,
        PacketType.alert,
        PacketType.assignment,
      ]) {
        final frame = encodeIbfs(_packet(
          type: type,
          text: '{"k":"x"}',
          priority: Priority.high,
        ));
        final decoded = decodeIbfs(frame);
        expect(decoded.type, type);
        expect(decoded.isStructured, isTrue);
        expect(decoded.priority, Priority.high);
      }
    });

    test('an alert raises the alarm and is labelled WARNING', () {
      final decoded = decodeIbfs(encodeIbfs(_packet(
        type: PacketType.alert,
        text: '{"note":"flood"}',
        priority: Priority.emergency,
      )));
      expect(decoded.raisesAlarm, isTrue);
      expect(decoded.alertLabel, 'WARNING');
    });

    test('a check-in with routine priority does not raise the alarm', () {
      final decoded = decodeIbfs(encodeIbfs(_packet(
        type: PacketType.checkIn,
        text: '{"k":"checkIn"}',
      )));
      expect(decoded.raisesAlarm, isFalse);
    });
  });

  group('IncidentReport', () {
    test('JSON round-trip preserves every coordination field', () {
      final now = DateTime.fromMillisecondsSinceEpoch(1700000000000);
      final report = IncidentReport(
        kind: IncidentKind.status,
        incidentId: 'A1B2',
        timestamp: now,
        sender: 'Rescue-1',
        lat: 17.385,
        lon: 78.4867,
        severity: 3,
        victims: 12,
        injured: 4,
        needs: {Need.water, Need.medical},
        note: 'School roof, water rising',
        battery: 23,
        radiusKm: 5.5,
        expiresAt: now.add(const Duration(hours: 3)),
      );

      final decoded = IncidentReport.fromJson(
        jsonDecode(report.toWireJson()) as Map<String, dynamic>,
      );

      expect(decoded.kind, IncidentKind.status);
      expect(decoded.incidentId, 'A1B2');
      expect(decoded.sender, 'Rescue-1');
      expect(decoded.lat, closeTo(17.385, 1e-6));
      expect(decoded.severity, 3);
      expect(decoded.victims, 12);
      expect(decoded.injured, 4);
      expect(decoded.needs, {Need.water, Need.medical});
      expect(decoded.note, 'School roof, water rising');
      expect(decoded.battery, 23);
      expect(decoded.radiusKm, closeTo(5.5, 1e-9));
      expect(decoded.expiresAt, isNotNull);
      expect(decoded.timestamp, now);
    });

    test('parses a JSON packet and takes position from the header', () {
      final report = IncidentReport.tryFromPacket(_packet(
        type: PacketType.statusReport,
        priority: Priority.emergency,
        lat: 19.07,
        lon: 72.87,
        text: jsonEncode({
          'k': 'status',
          'id': '9XYZ',
          'ts': 1700000000000,
          'sev': 2,
          'vic': 7,
          'need': ['food', 'rescue'],
          'note': 'Terrace, no food',
        }),
      ))!;

      expect(report.kind, IncidentKind.status);
      expect(report.incidentId, '9XYZ');
      expect(report.victims, 7);
      expect(report.needs, {Need.food, Need.rescue});
      expect(report.lat, closeTo(19.07, 1e-6));
      expect(report.lon, closeTo(72.87, 1e-6));
      expect(report.sender, 'Asha');
      expect(report.summaryLine, contains('7 victims'));
      expect(report.summaryLine, contains('food'));
    });

    test('a plain-text SOS from an older build still becomes a report', () {
      final report = IncidentReport.tryFromPacket(_packet(
        type: PacketType.silentSos,
        priority: Priority.emergency,
        text: 'SOS — trapped under debris',
      ))!;
      expect(report.kind, IncidentKind.sos);
      expect(report.severity, 3);
      expect(report.summaryLine, 'SOS — trapped under debris');
    });

    test('a voice packet is not a structured report', () {
      final report = IncidentReport.tryFromPacket(_packet(
        type: PacketType.pttVoice,
        text: 'hello',
      ));
      expect(report, isNull);
    });

    test('summary lines read as sentences, not JSON', () {
      final checkIn = IncidentReport(
        kind: IncidentKind.checkIn,
        incidentId: 'C1',
        timestamp: DateTime.now(),
        safe: true,
        peopleSafe: 4,
        peopleMissing: 2,
      );
      expect(checkIn.summaryLine, 'Safe · 4 here · 2 missing');

      final unsafe = IncidentReport(
        kind: IncidentKind.checkIn,
        incidentId: 'C2',
        timestamp: DateTime.now(),
        safe: false,
        peopleMissing: 3,
      );
      expect(unsafe.summaryLine, 'NOT SAFE · 3 missing');
    });
  });

  group('IncidentBoard', () {
    test('aggregates SOS, safe, missing and injured totals', () {
      final board = IncidentBoard();
      final now = DateTime.now();

      board.upsert(IncidentReport(
        kind: IncidentKind.sos,
        incidentId: 'S1',
        timestamp: now,
        severity: 3,
      ));
      board.upsert(IncidentReport(
        kind: IncidentKind.checkIn,
        incidentId: 'C1',
        timestamp: now,
        safe: true,
        peopleSafe: 5,
      ));
      board.upsert(IncidentReport(
        kind: IncidentKind.checkIn,
        incidentId: 'C2',
        timestamp: now,
        safe: false,
        peopleMissing: 2,
      ));
      board.upsert(IncidentReport(
        kind: IncidentKind.status,
        incidentId: 'N1',
        timestamp: now,
        severity: 2,
        victims: 9,
        injured: 4,
        needs: {Need.water, Need.medical},
      ));
      board.upsert(IncidentReport(
        kind: IncidentKind.warning,
        incidentId: 'W1',
        timestamp: now,
        severity: 3,
        note: 'Flood',
      ));

      final counts = board.counts;
      expect(counts.sos, 1);
      expect(counts.warnings, 1);
      expect(counts.safe, 5);
      expect(counts.missing, 2);
      expect(counts.injured, 4);
      expect(counts.open, 1);
      expect(board.length, 5);
      expect(board.needTotals[Need.water], 1);
      expect(board.needTotals[Need.medical], 1);

      // Most urgent first.
      expect(board.reports.first.severity, 3);
    });

    test('an assignment updates the incident instead of adding a row', () {
      final board = IncidentBoard();
      board.upsert(IncidentReport(
        kind: IncidentKind.sos,
        incidentId: 'S9',
        timestamp: DateTime.now(),
        severity: 3,
      ));

      board.upsert(IncidentReport(
        kind: IncidentKind.assignment,
        incidentId: 'S9',
        timestamp: DateTime.now().add(const Duration(seconds: 1)),
        severity: 2,
        status: IncidentStatus.assigned,
        assignedTeam: 'Rescue-2',
        etaMinutes: 25,
      ));

      expect(board.length, 1);
      final report = board.byId('S9')!;
      expect(report.kind, IncidentKind.sos);
      expect(report.status, IncidentStatus.assigned);
      expect(report.assignedTeam, 'Rescue-2');
      expect(report.etaMinutes, 25);
    });

    test('a replayed older report does not roll back state', () {
      final board = IncidentBoard();
      final now = DateTime.now();
      board.upsert(IncidentReport(
        kind: IncidentKind.sos,
        incidentId: 'S2',
        timestamp: now,
        severity: 3,
        status: IncidentStatus.assigned,
      ));
      board.upsert(IncidentReport(
        kind: IncidentKind.sos,
        incidentId: 'S2',
        timestamp: now.subtract(const Duration(minutes: 5)),
        severity: 3,
      ));
      expect(board.byId('S2')!.status, IncidentStatus.assigned);
    });

    test('resolve marks an incident and removes it from SOS counts', () {
      final board = IncidentBoard();
      board.upsert(IncidentReport(
        kind: IncidentKind.sos,
        incidentId: 'S3',
        timestamp: DateTime.now(),
        severity: 3,
      ));
      expect(board.counts.sos, 1);
      expect(board.resolve('S3'), isTrue);
      expect(board.counts.sos, 0);
      expect(board.byId('S3')!.status, IncidentStatus.resolved);
    });

    test('loads persisted reports from a previous session', () async {
      final saved = IncidentReport(
        kind: IncidentKind.sos,
        incidentId: 'P1',
        timestamp: DateTime.now(),
        severity: 3,
        note: 'SOS from yesterday',
      ).toJson();
      SharedPreferences.setMockInitialValues({
        'itantra_incidents': jsonEncode([saved]),
      });

      final board = IncidentBoard();
      await board.load();
      expect(board.length, 1);
      expect(board.byId('P1')!.note, 'SOS from yesterday');
    });
  });
}
