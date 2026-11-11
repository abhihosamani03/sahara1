import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:itantra/ml/ibfs.dart';
import 'package:itantra/ml/languages.dart';
import 'package:itantra/net/store_forward.dart';
import 'package:itantra/net/transport.dart';

/// Transport that records frames instead of touching a radio.
class _RecordingTransport implements Transport {
  final List<Uint8List> sent = [];
  bool connected = true;
  final _controller = StreamController<Uint8List>.broadcast();

  @override
  Future<int> send(Uint8List frame) async {
    if (!connected) throw StateError('offline');
    sent.add(frame);
    return 1;
  }

  @override
  Stream<Uint8List> get incoming => _controller.stream;

  @override
  bool get isConnected => connected;

  @override
  Future<void> disconnect() async {
    await _controller.close();
  }
}

Uint8List _frame({
  required int sequenceId,
  required Priority priority,
  PacketType type = PacketType.pttVoice,
  String text = 'hello',
}) =>
    encodeIbfs(IbfPacket(
      type: type,
      priority: priority,
      language: kEnglish,
      sequenceId: sequenceId,
      text: text,
    ));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Delivery receipts (ACK, packet type 0x3)', () {
    test('an ACK carries the confirmed sequence id in its payload', () {
      final frame = _frame(
        sequenceId: 9001,
        priority: Priority.routine,
        type: PacketType.ack,
        text: '4242',
      );
      final packet = decodeIbfs(frame);

      expect(packet.isAck, isTrue);
      expect(packet.ackedSequenceId, 4242);
      // A receipt must never raise an alarm or be spoken.
      expect(packet.raisesAlarm, isFalse);
    });

    test('an ACK keeps its own sequence id for mesh dedup', () {
      // Reusing the confirmed ID would make the receipt a duplicate of the
      // frame it confirms, so the mesh would drop it before the sender saw it.
      final confirmed = _frame(sequenceId: 4242, priority: Priority.routine);
      final receipt = _frame(
        sequenceId: 9001,
        priority: Priority.routine,
        type: PacketType.ack,
        text: '4242',
      );

      expect(ByteData.sublistView(confirmed).getUint32(4, Endian.big), 4242);
      expect(ByteData.sublistView(receipt).getUint32(4, Endian.big), 9001);
      expect(decodeIbfs(receipt).ackedSequenceId, 4242);
    });

    test('a malformed ACK payload yields no confirmed id instead of throwing',
        () {
      final packet = decodeIbfs(_frame(
        sequenceId: 1,
        priority: Priority.routine,
        type: PacketType.ack,
        text: 'not-a-number',
      ));
      expect(packet.ackedSequenceId, isNull);
    });
  });

  group('StoreForwardQueue hygiene', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    test('emergency frames flush before routine frames', () async {
      // Hold the link down while filling the queue so the flush order is
      // deterministic instead of racing the enqueue-triggered flush.
      final transport = _RecordingTransport()..connected = false;
      final queue = StoreForwardQueue(transport, startTimer: false);

      queue.enqueue(_frame(sequenceId: 1, priority: Priority.routine));
      queue.enqueue(_frame(
        sequenceId: 2,
        priority: Priority.emergency,
        type: PacketType.silentSos,
        text: 'SOS',
      ));
      queue.enqueue(_frame(sequenceId: 3, priority: Priority.high));

      transport.connected = true;
      await queue.flushNow();

      final order = transport.sent
          .map((f) => ByteData.sublistView(f).getUint32(4, Endian.big))
          .toList();
      expect(order, [2, 3, 1]);
      expect(queue.pendingCount, 0);
      queue.dispose();
    });

    test('entries older than maxAge are dropped, not replayed', () async {
      var now = DateTime(2026, 1, 1, 12);
      final transport = _RecordingTransport()..connected = false;
      final queue = StoreForwardQueue(
        transport,
        maxAge: const Duration(hours: 6),
        clock: () => now,
        startTimer: false,
      );

      queue.enqueue(_frame(sequenceId: 1, priority: Priority.emergency));
      expect(queue.pendingCount, 1);

      now = now.add(const Duration(hours: 7));
      transport.connected = true;
      await queue.flushNow();

      expect(queue.pendingCount, 0);
      expect(transport.sent, isEmpty);
      queue.dispose();
    });

    test('the size cap drops the lowest priority, oldest entry first', () {
      final transport = _RecordingTransport()..connected = false;
      final queue = StoreForwardQueue(
        transport,
        maxEntries: 2,
        startTimer: false,
      );

      queue.enqueue(_frame(sequenceId: 1, priority: Priority.routine));
      queue.enqueue(_frame(sequenceId: 2, priority: Priority.routine));
      queue.enqueue(_frame(
        sequenceId: 3,
        priority: Priority.emergency,
        type: PacketType.silentSos,
        text: 'SOS',
      ));

      final kept = queue.pending.map((e) => e.sequenceId).toList();
      expect(queue.pendingCount, 2);
      expect(kept, contains(3));
      expect(kept, isNot(contains(1)));
      queue.dispose();
    });

    test('a delivery receipt removes the queued copy', () {
      final transport = _RecordingTransport()..connected = false;
      final queue = StoreForwardQueue(transport, startTimer: false);

      queue.enqueue(_frame(sequenceId: 77, priority: Priority.routine));
      expect(queue.removeBySequenceId(77), isTrue);
      expect(queue.pendingCount, 0);
      expect(queue.removeBySequenceId(77), isFalse);
      queue.dispose();
    });

    test('queued priority is recovered from the frame header', () {
      final transport = _RecordingTransport()..connected = false;
      final queue = StoreForwardQueue(transport, startTimer: false);

      queue.enqueue(_frame(
        sequenceId: 5,
        priority: Priority.emergency,
        type: PacketType.silentSos,
        text: 'SOS',
      ));

      expect(queue.pending.single.isEmergency, isTrue);
      queue.dispose();
    });

    test('dispose stops the retry timer without throwing', () {
      final transport = _RecordingTransport();
      final queue = StoreForwardQueue(transport);
      expect(() => queue.dispose(), returnsNormally);
    });
  });
}
