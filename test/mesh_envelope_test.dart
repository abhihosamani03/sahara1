import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:itantra/ml/ibfs.dart';
import 'package:itantra/ml/languages.dart';
import 'package:itantra/net/mesh_envelope.dart';

Uint8List _frame({int seq = 42, String text = 'hello'}) => encodeIbfs(IbfPacket(
      type: PacketType.pttVoice,
      priority: Priority.routine,
      language: kEnglish,
      sequenceId: seq,
      text: text,
    ));

void main() {
  group('Mesh v3 envelope', () {
    test('round-trips an iBFS frame without touching its bytes', () {
      final frame = _frame(seq: 0xDEADBEEF, text: 'बाढ़');
      final wire = encodeMeshEnvelope(
        frame: frame,
        origin: 0x1234,
        dest: 0x5678,
        ttl: 5,
        hop: 2,
      );

      expect(isMeshEnvelope(wire), isTrue);
      final env = decodeMeshEnvelope(wire)!;
      expect(env.origin, 0x1234);
      expect(env.dest, 0x5678);
      expect(env.ttl, 5);
      expect(env.hop, 2);
      expect(env.frame, equals(frame));

      // The inner frame still decodes: the envelope must not disturb it.
      final decoded = decodeIbfs(env.frame);
      expect(decoded.sequenceId, 0xDEADBEEF);
      expect(decoded.text, 'बाढ़');
    });

    test('forwarding decrements TTL, increments hop, keeps the frame', () {
      final frame = _frame();
      final env = decodeMeshEnvelope(encodeMeshEnvelope(
        frame: frame,
        origin: 7,
        ttl: 3,
        hop: 1,
      ))!;

      final next = env.forwarded(relay: 9)!;
      expect(next.ttl, 2);
      expect(next.hop, 2);
      expect(next.origin, 7);
      expect(next.path, [9]);
      expect(next.frame, equals(frame));

      // TTL 1 is delivered, never forwarded.
      final last = MeshEnvelope(
        ttl: 1,
        hop: 4,
        origin: 7,
        dest: kBroadcastNode,
        frame: frame,
      );
      expect(last.forwarded(relay: 3), isNull);
    });

    test('next hop and path survive a round trip', () {
      final wire = encodeMeshEnvelope(
        frame: _frame(),
        origin: 4,
        dest: 77,
        nextHop: 12,
        path: const [3, 8, 12],
      );
      final env = decodeMeshEnvelope(wire)!;
      expect(env.nextHop, 12);
      expect(env.path, [3, 8, 12]);
      expect(env.shouldRelayAt(12), isTrue);
      expect(env.shouldRelayAt(8), isFalse);
      expect(env.shouldRelayAt(99), isFalse);
    });

    test('broadcast vs targeted destination', () {
      final frame = _frame();
      final broadcast = decodeMeshEnvelope(
        encodeMeshEnvelope(frame: frame, origin: 1),
      )!;
      expect(broadcast.isBroadcast, isTrue);
      expect(broadcast.ttl, kDefaultTtl);

      final targeted = decodeMeshEnvelope(
        encodeMeshEnvelope(frame: frame, origin: 1, dest: 99),
      )!;
      expect(targeted.isBroadcast, isFalse);
      expect(targeted.dest, 99);
    });

    test('rejects bad magic, wrong version, truncated and zero TTL', () {
      final frame = _frame();
      final wire = encodeMeshEnvelope(frame: frame, origin: 5);

      final badMagic = Uint8List.fromList(wire)..[0] = 0x00;
      expect(isMeshEnvelope(badMagic), isFalse);
      expect(decodeMeshEnvelope(badMagic), isNull);

      final badVersion = Uint8List.fromList(wire)..[2] = 0x01;
      expect(isMeshEnvelope(badVersion), isFalse);

      final zeroTtl = Uint8List.fromList(wire)..[3] = 0;
      expect(decodeMeshEnvelope(zeroTtl), isNull);

      final truncated =
          Uint8List.sublistView(wire, 0, kMeshHeaderLen + 13);
      expect(isMeshEnvelope(truncated), isFalse);
    });

    test('a raw iBFS frame is not mistaken for an envelope', () {
      final frame = _frame();
      expect(isMeshEnvelope(frame), isFalse);
      expect(decodeMeshEnvelope(frame), isNull);
      expect(innerFrame(frame), equals(frame));
    });

    test('refuses reserved origin IDs and short inner frames', () {
      final frame = _frame();
      expect(
        () => encodeMeshEnvelope(frame: frame, origin: 0),
        throwsArgumentError,
      );
      expect(
        () => encodeMeshEnvelope(frame: frame, origin: kBroadcastNode),
        throwsArgumentError,
      );
      expect(
        () => encodeMeshEnvelope(
          frame: Uint8List(4),
          origin: 3,
        ),
        throwsArgumentError,
      );
    });

    test('TTL is clamped to the protocol ceiling', () {
      final env = decodeMeshEnvelope(encodeMeshEnvelope(
        frame: _frame(),
        origin: 3,
        ttl: 200,
      ))!;
      expect(env.ttl, kMaxTtl);
    });
  });
}
