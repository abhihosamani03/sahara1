import 'package:flutter_test/flutter_test.dart';
import 'package:itantra/state/missing_registry.dart';
import 'package:shared_preferences/shared_preferences.dart';

MissingPerson _person({String id = 'P1', DateTime? at, String name = 'Asha'}) =>
    MissingPerson(
      id: id,
      name: name,
      updatedAt: at ?? DateTime(2026, 11, 6, 12),
      age: 9,
      lastSeen: 'Ward 4',
      photoPath: '/tmp/asha.jpg',
      reportedBy: 'post-1',
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('wire form omits the local photo path', () {
    final wire = _person().toWireJson();
    expect(wire, contains('Asha'));
    expect(wire, isNot(contains('/tmp/asha.jpg')));
    expect(MissingPerson.tryParse(wire)!.photoPath, isNull);
  });

  test('registry keeps the newest record and ignores replays', () {
    final registry = MissingRegistry();
    expect(registry.upsert(_person()), isTrue);
    expect(
      registry.upsert(_person(
        name: 'Asha (found)',
        at: DateTime(2026, 11, 6, 13),
      )),
      isTrue,
    );
    expect(registry.entries.single.name, 'Asha (found)');
    expect(registry.upsert(_person(name: 'stale')), isFalse);
  });

  test('empty names and ids are rejected', () {
    final registry = MissingRegistry();
    expect(
      registry.upsert(MissingPerson(id: '', name: 'x', updatedAt: DateTime.now())),
      isFalse,
    );
    expect(
      registry.upsert(MissingPerson(id: 'P2', name: '  ', updatedAt: DateTime.now())),
      isFalse,
    );
  });

  test('remove drops one record', () {
    final registry = MissingRegistry();
    registry.upsert(_person());
    expect(registry.remove('P1'), isTrue);
    expect(registry.isEmpty, isTrue);
  });

  test('malformed wire text is not accepted', () {
    expect(MissingPerson.tryParse('{}'), isNull);
    expect(MissingPerson.tryParse('nope'), isNull);
  });
}
