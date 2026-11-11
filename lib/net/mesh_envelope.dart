import 'dart:typed_data';

/// Mesh envelope — docs/NETWORK_PROTOCOL.md §2.1.
///
/// iBFS frames carry no routing information: no hop limit, no sender identity
/// and no destination. The envelope wraps an unmodified iBFS frame in a small
/// routing header so the mesh can stop flooding, address one node, and report
/// how a frame travelled.
///
/// **v3 layout (big-endian):**
///
/// ```text
/// Byte 0-1   Magic "MS" (0x4D 0x53)
/// Byte 2     Envelope version (0x03)
/// Byte 3     TTL — relays remaining, 1..15
/// Byte 4     Hop count — incremented by every relay
/// Byte 5-6   Origin node ID (uint16, never 0 or 0xFFFF)
/// Byte 7-8   Destination node ID (uint16, 0xFFFF = broadcast)
/// Byte 9-10  Next hop (uint16, 0 = flood; otherwise only that node relays)
/// Byte 11    Path length (0..8)
/// Byte 12..  Path: node IDs of the relays already traversed, 2 bytes each
/// ...        Unmodified iBFS frame (starts 0x49 0x54)
/// ```
///
/// v2 frames (9-byte header, no next hop and no path) are still decoded and
/// delivered, so a receiver is not the cause of a dropped frame during a mixed
/// rollout. Everything this build emits is v3.
class MeshEnvelope {
  const MeshEnvelope({
    required this.ttl,
    required this.hop,
    required this.origin,
    required this.dest,
    required this.frame,
    this.nextHop = 0,
    this.path = const <int>[],
    this.version = kMeshEnvelopeVersion,
  });

  /// Relays remaining, 1..[kMaxTtl]. A frame with TTL 1 is delivered but not
  /// forwarded.
  final int ttl;

  /// Hops already travelled.
  final int hop;

  /// Node ID of the original sender.
  final int origin;

  /// Target node ID, or [kBroadcastNode].
  final int dest;

  /// Node ID that should relay this frame next, or 0 for a flood.
  final int nextHop;

  /// Relay node IDs already traversed, oldest first.
  final List<int> path;

  /// Envelope version this object was decoded from.
  final int version;

  /// The wrapped iBFS frame, byte-for-byte.
  final Uint8List frame;

  bool get isBroadcast => dest == kBroadcastNode;

  /// Whether this frame should be relayed by [nodeId].
  ///
  /// A next hop of 0 is a flood (the mesh has no route yet); otherwise only the
  /// named neighbour forwards it, which is what keeps a targeted message from
  /// being re-transmitted by every phone in range.
  bool shouldRelayAt(int nodeId) => nextHop == 0 || nextHop == nodeId;

  /// Returns the envelope as it should leave a relay: one hop further, one
  /// relay closer to expiry, and with [relay] appended to the path.
  ///
  /// Returns `null` when it must not be forwarded.
  MeshEnvelope? forwarded({required int relay, int? nextHop}) {
    if (ttl <= 1) return null;
    final trace = path.length >= kMaxPathNodes
        ? path
        : <int>[...path, relay];
    return MeshEnvelope(
      ttl: ttl - 1,
      hop: hop + 1,
      origin: origin,
      dest: dest,
      nextHop: nextHop ?? this.nextHop,
      path: trace,
      frame: frame,
    );
  }
}

/// "MS" — mesh envelope magic.
const int kMeshMagic0 = 0x4D;
const int kMeshMagic1 = 0x53;

/// Envelope version emitted by this build.
const int kMeshEnvelopeVersion = 3;

/// Oldest envelope version still accepted.
const int kMeshMinEnvelopeVersion = 2;

/// v2 header size before the wrapped iBFS frame.
const int kMeshHeaderLenV2 = 9;

/// v3 fixed header size, excluding the path array.
const int kMeshHeaderLen = 12;

/// Broadcast destination.
const int kBroadcastNode = 0xFFFF;

/// No next hop: flood.
const int kFloodNextHop = 0;

/// Maximum relays recorded in the path trace.
const int kMaxPathNodes = 8;

/// Default hop budget. Five relays is roughly 250–500 m per hop on BLE, so this
/// reaches a village block without letting a frame circle the mesh.
const int kDefaultTtl = 5;

/// Hard ceiling on a TTL byte, so a corrupted header cannot create a storm.
const int kMaxTtl = 15;

/// Header length (including path) for [bytes], or `null` if malformed.
int? meshHeaderLength(Uint8List bytes) {
  if (bytes.length < kMeshHeaderLenV2 + 14) return null;
  if (bytes[0] != kMeshMagic0 || bytes[1] != kMeshMagic1) return null;
  if (bytes[2] == kMeshEnvelopeVersion) {
    final pathLen = bytes[kMeshHeaderLen - 1];
    if (pathLen > kMaxPathNodes) return null;
    final len = kMeshHeaderLen + pathLen * 2;
    if (bytes.length < len + 14) return null;
    return len;
  }
  if (bytes[2] == 2) return kMeshHeaderLenV2;
  return null;
}

/// Whether [bytes] begins with a well-formed envelope header (v2 or v3).
bool isMeshEnvelope(Uint8List bytes) => meshHeaderLength(bytes) != null;

/// Decode an envelope, or `null` when the bytes are not a valid envelope.
MeshEnvelope? decodeMeshEnvelope(Uint8List bytes) {
  final headerLen = meshHeaderLength(bytes);
  if (headerLen == null) return null;
  final view = ByteData.sublistView(bytes);
  final version = bytes[2];
  final ttl = bytes[3];
  final hop = bytes[4];
  // A zero/oversized TTL is a corrupted header, not a message.
  if (ttl < 1 || ttl > kMaxTtl) return null;
  final origin = view.getUint16(5, Endian.big);
  // 0 is reserved and can never be an origin.
  if (origin == 0) return null;

  if (version == 2) {
    return MeshEnvelope(
      ttl: ttl,
      hop: hop,
      origin: origin,
      dest: view.getUint16(7, Endian.big),
      version: 2,
      // sublistView keeps the offset of the original buffer, which is what BLE
      // chunk reassembly produces.
      frame: Uint8List.sublistView(bytes, headerLen),
    );
  }

  final nextHop = view.getUint16(9, Endian.big);
  final pathLen = bytes[kMeshHeaderLen - 1];
  final path = <int>[];
  for (var i = 0; i < pathLen; i++) {
    path.add(view.getUint16(kMeshHeaderLen + i * 2, Endian.big));
  }
  return MeshEnvelope(
    ttl: ttl,
    hop: hop,
    origin: origin,
    dest: view.getUint16(7, Endian.big),
    nextHop: nextHop,
    path: path,
    version: 3,
    frame: Uint8List.sublistView(bytes, headerLen),
  );
}

/// Wrap [frame] in a v3 envelope.
Uint8List encodeMeshEnvelope({
  required Uint8List frame,
  required int origin,
  int dest = kBroadcastNode,
  int ttl = kDefaultTtl,
  int hop = 0,
  int nextHop = kFloodNextHop,
  List<int> path = const <int>[],
}) {
  if (frame.length < 14) {
    throw ArgumentError('Inner frame too short: ${frame.length}');
  }
  if (origin == 0 || origin == kBroadcastNode) {
    throw ArgumentError('Origin must be a real node ID: $origin');
  }
  if (path.length > kMaxPathNodes) {
    throw ArgumentError('Path too long: ${path.length}');
  }
  final safeTtl = ttl.clamp(1, kMaxTtl);
  final out = Uint8List(kMeshHeaderLen + path.length * 2 + frame.length);
  final view = ByteData.sublistView(out);
  out[0] = kMeshMagic0;
  out[1] = kMeshMagic1;
  out[2] = kMeshEnvelopeVersion;
  out[3] = safeTtl;
  out[4] = hop & 0xFF;
  view.setUint16(5, origin, Endian.big);
  view.setUint16(7, dest, Endian.big);
  view.setUint16(9, nextHop, Endian.big);
  out[kMeshHeaderLen - 1] = path.length;
  for (var i = 0; i < path.length; i++) {
    view.setUint16(kMeshHeaderLen + i * 2, path[i], Endian.big);
  }
  out.setRange(kMeshHeaderLen + path.length * 2, out.length, frame);
  return out;
}

/// The iBFS frame inside [bytes], whether or not it is enveloped.
Uint8List innerFrame(Uint8List bytes) {
  final env = decodeMeshEnvelope(bytes);
  return env?.frame ?? bytes;
}
