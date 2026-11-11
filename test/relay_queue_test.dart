import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:itantra/ml/ibfs.dart';
import 'package:itantra/ml/languages.dart';
import 'package:itantra/net/mesh_envelope.dart';
import 'package:itantra/net/relay_queue.dart';

Uint8List _wire(int seq, {int dest = kBroadcastNode}) => encodeMeshEnvelope(
      frame: encodeIbfs(IbfPacket(
        type: PacketType.pttVoice,
        priority: Priority.routine,
        language: kEnglish,
        sequenceId: seq,
        text: 'relay me',
      )),
      origin: 7,
      dest: dest,
    );

void main() {
  test('queues a transit frame and drops an exact duplicate', () {
    final queue = RelayQueue();
    expect(queue.enqueue(_wire(100)), 1);
    expect(queue.enqueue(_wire(100)), 1);
    expect(queue.length, 1);
    expect(queue.pendingSequenceIds, [100]);
  });

  test('ignores raw frames with no envelope', () {
    final queue = RelayQueue();
    final raw = encodeIbfs(IbfPacket(
      type: PacketType.pttVoice,
      priority: Priority.routine,
      language: kEnglish,
      sequenceId: 5,
      text: 'legacy',
    ));
    expect(queue.enqueue(raw), 0);
  });

  test('flush removes only frames a peer actually took', () async {
    final queue = RelayQueue();
    queue.enqueue(_wire(1));
    queue.enqueue(_wire(2));

    final delivered = await queue.flush((wire) async {
      final seq = ByteData.sublistView(wire, kMeshHeaderLen)
          .getUint32(4, Endian.big);
      return seq == 1 ? 2 : 0;
    });

    expect(delivered, 1);
    expect(queue.pendingSequenceIds, [2]);
  });

  test('a throwing radio keeps the frame for the next attempt', () async {
    final queue = RelayQueue();
    queue.enqueue(_wire(9));
    final delivered = await queue.flush((_) async => throw StateError('down'));
    expect(delivered, 0);
    expect(queue.length, 1);
  });

  test('expired frames are purged', () async {
    var now = DateTime(2026, 1, 1, 12);
    final queue = RelayQueue(
      maxAge: const Duration(minutes: 5),
      clock: () => now,
    );
    queue.enqueue(_wire(3));
    now = now.add(const Duration(minutes: 6));
    final delivered = await queue.flush((_) async => 1);
    expect(delivered, 0);
    expect(queue.isEmpty, isTrue);
  });

  test('respects the entry cap', () {
    final queue = RelayQueue(maxEntries: 2);
    queue.enqueue(_wire(1));
    queue.enqueue(_wire(2));
    queue.enqueue(_wire(3));
    expect(queue.length, 2);
  });
}
