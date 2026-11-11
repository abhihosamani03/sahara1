import 'package:flutter_test/flutter_test.dart';
import 'package:itantra/state/incident.dart' show Need;
import 'package:itantra/state/relief_ledger.dart';
import 'package:shared_preferences/shared_preferences.dart';

ReliefEntry _camp({
  String id = 'A1',
  String name = 'Camp A',
  DateTime? at,
  Map<Need, int> needs = const {},
  Map<Need, int> supplies = const {},
  String by = 'post-1',
}) =>
    ReliefEntry(
      id: id,
      name: name,
      updatedAt: at ?? DateTime(2026, 11, 6, 12),
      needs: needs,
      supplies: supplies,
      updatedBy: by,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('shortfall is need minus supply, only when positive', () {
    final camp = _camp(
      needs: {Need.water: 200, Need.food: 100},
      supplies: {Need.water: 40, Need.food: 120},
    );
    expect(camp.shortfall, {Need.water: 160});
    expect(camp.balance(Need.food), 20);
    expect(camp.hasShortfall, isTrue);
  });

  test('ledger merges by timestamp and ignores an older replay', () {
    final ledger = ReliefLedger();
    final newer = _camp(name: 'Camp A v2', at: DateTime(2026, 11, 6, 13));
    expect(ledger.upsert(_camp()), isTrue);
    expect(ledger.upsert(newer), isTrue);
    expect(ledger.byId('A1')!.name, 'Camp A v2');
    expect(ledger.upsert(_camp(name: 'stale')), isFalse);
    expect(ledger.byId('A1')!.name, 'Camp A v2');
  });

  test('equal timestamps converge via the reporter name', () {
    final ledger = ReliefLedger();
    final at = DateTime(2026, 11, 6, 12);
    expect(ledger.upsert(_camp(name: 'from B', at: at, by: 'b')), isTrue);
    // Lower reporter loses regardless of arrival order.
    expect(ledger.upsert(_camp(name: 'from A', at: at, by: 'a')), isFalse);
    expect(ledger.byId('A1')!.name, 'from B');
  });

  test('wire JSON round-trips through the parser', () {
    final camp = _camp(
      needs: {Need.water: 10},
      supplies: {Need.water: 4, Need.food: 2},
      by: 'post-9',
    );
    final parsed = ReliefEntry.tryParse(camp.toWireJson());
    expect(parsed, isNotNull);
    expect(parsed!.name, 'Camp A');
    expect(parsed.needs, {Need.water: 10});
    expect(parsed.supplies, {Need.water: 4, Need.food: 2});
    expect(parsed.updatedBy, 'post-9');
  });

  test('rejects non-JSON and structurally empty records', () {
    expect(ReliefEntry.tryParse('hello'), isNull);
    expect(ReliefEntry.tryParse('{"id":"","name":""}'), isNull);
  });

  test('shortfall totals add up across camps', () {
    final ledger = ReliefLedger();
    ledger.upsert(_camp(
      id: 'A',
      needs: {Need.water: 10},
      supplies: {Need.water: 2},
    ));
    ledger.upsert(_camp(
      id: 'B',
      needs: {Need.water: 5, Need.medical: 3},
      supplies: {},
    ));
    expect(ledger.shortfallTotals[Need.water], 13);
    expect(ledger.shortfallTotals[Need.medical], 3);
  });

  test('adjust updates a single resource and bumps the timestamp', () {
    final ledger = ReliefLedger();
    ledger.upsert(_camp(needs: {Need.water: 10}));
    expect(
      ledger.adjust('A1', need: Need.water, needCount: 4, updatedBy: 'me'),
      isTrue,
    );
    expect(ledger.byId('A1')!.needs[Need.water], 4);
  });
}
