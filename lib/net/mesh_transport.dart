import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';

import 'ble_transport.dart';
import 'coded_phy.dart';
import 'mesh_envelope.dart';
import 'relay_queue.dart';
import 'transport.dart';
import 'wifi_aware_transport.dart';
import 'wifi_direct_transport.dart';

/// Snapshot of the live radio state, for the UI and for logging.
class LinkStats {
  const LinkStats({
    required this.bleRunning,
    required this.bleScanning,
    required this.blePeers,
    required this.bleKnownPeers,
    required this.bleStatus,
    required this.wifiDirectRunning,
    required this.wifiDirectSupported,
    required this.wifiDirectPeers,
    required this.wifiDirectStatus,
    this.bleError,
    this.wifiDirectError,
    this.codedPhyRunning = false,
    this.codedPhySupported = false,
    this.codedPhyPeers = 0,
    this.codedPhyStatus = 'off',
    this.codedPhyActive = false,
    this.codedPhyError,
    this.wifiAwareRunning = false,
    this.wifiAwareSupported = false,
    this.wifiAwarePeers = 0,
    this.wifiAwareStatus = 'off',
    this.wifiAwareError,
    this.routeCount = 0,
    this.relayMode = false,
  });

  final bool bleRunning;
  final bool bleScanning;
  final int blePeers;
  final int bleKnownPeers;
  final String bleStatus;

  final bool wifiDirectRunning;
  final bool wifiDirectSupported;
  final int wifiDirectPeers;
  final String wifiDirectStatus;

  /// Why Bluetooth failed to start, if it did.
  final String? bleError;

  /// Why Wi-Fi Direct failed to start, if it did.
  final String? wifiDirectError;

  /// Long-range BLE (LE Coded PHY) state.
  final bool codedPhyRunning;
  final bool codedPhySupported;
  final int codedPhyPeers;
  final String codedPhyStatus;

  /// Whether a live link is actually running on the Coded PHY. False while the
  /// radio is up means the range benefit is not in effect.
  final bool codedPhyActive;
  final String? codedPhyError;

  /// Wi-Fi Aware (NAN) state.
  final bool wifiAwareRunning;
  final bool wifiAwareSupported;
  final int wifiAwarePeers;
  final String wifiAwareStatus;
  final String? wifiAwareError;

  /// Number of destinations with a learned next hop.
  final int routeCount;

  /// Whether this phone is running as a radio relay only.
  final bool relayMode;

  /// Peers we can exchange frames with, across all radios.
  int get totalPeers =>
      blePeers + wifiDirectPeers + wifiAwarePeers + codedPhyPeers;

  /// Whether any radio is up (a link may exist even with 0 peers so far).
  bool get anyRunning =>
      bleRunning || wifiDirectRunning || wifiAwareRunning || codedPhyRunning;

  bool get hasPeers => totalPeers > 0;

  /// Short badge text (the app-bar pill).
  String get label {
    if (hasPeers) return '$totalPeers peer${totalPeers == 1 ? '' : 's'}';
    if (anyRunning) return bleScanning ? 'searching' : 'listening';
    return 'offline';
  }

  /// A single actionable sentence when both radios are down, otherwise null.
  String? get failureHint {
    if (anyRunning) return null;
    final parts = <String>[
      if (bleError != null) 'Bluetooth: $bleError',
      if (wifiDirectError != null) 'Wi-Fi Direct: $wifiDirectError',
      if (wifiAwareError != null) 'Wi-Fi Aware: $wifiAwareError',
    ];
    if (parts.isEmpty) {
      return 'No radio is available — turn on Bluetooth, or turn on Wi-Fi '
          '(you do not need to join a network) for Wi-Fi Direct.';
    }
    return '${parts.join(' · ')}. Turn on Bluetooth (and Wi-Fi for Wi-Fi '
        'Direct — no network or hotspot needed).';
  }

  /// Actionable guidance shown while a radio is up but no peer has been found
  /// yet. Without it "searching" looks identical to "broken".
  String get searchHint {
    if (hasPeers) return '';
    if (!anyRunning) return failureHint ?? '';
    return 'Radios are up but no peer yet — keep Sahara open on the other '
        'phone, and make sure Bluetooth and Wi-Fi are on and Location is '
        'enabled (Android hides BLE and Wi-Fi Direct scan results when '
        'Location is off).';
  }

  /// Long form for tooltips / the status banner.
  String get detail {
    final ble = bleRunning ? 'BLE $bleStatus' : 'BLE off';
    final range = !codedPhySupported
        ? 'long range unsupported'
        : codedPhyRunning
            ? (codedPhyActive ? 'Coded PHY $codedPhyStatus' : 'Coded PHY 1M')
            : 'long range idle';
    final aware = !wifiAwareSupported
        ? 'Wi-Fi Aware unsupported'
        : wifiAwareRunning
            ? 'Wi-Fi Aware $wifiAwareStatus'
            : 'Wi-Fi Aware idle';
    final wifi = !wifiDirectSupported
        ? 'Wi-Fi Direct unsupported'
        : wifiDirectRunning
            ? 'Wi-Fi Direct $wifiDirectStatus'
            : 'Wi-Fi Direct idle';
    return '$ble · $range · $aware · $wifi';
  }

  /// Used to detect changes without spamming the UI.
  String get signature =>
      '$bleRunning/$bleScanning/$blePeers/$bleKnownPeers/$wifiDirectRunning/'
      '$wifiDirectPeers/$wifiDirectStatus/$codedPhyRunning/$codedPhyPeers/'
      '$codedPhyActive/$wifiAwareRunning/$wifiAwarePeers/$wifiAwareStatus/'
      '$routeCount/$relayMode';
}

/// One radio peer's signal strength, for coarse proximity homing.
///
/// RSSI is a distance hint only: it carries no bearing, and body blocking or
/// antenna orientation can swing it by 20 dB. The UI must never present it as
/// a direction.
class PeerSignal {
  const PeerSignal({required this.id, required this.rssi, required this.ble});

  final String id;
  final int rssi;
  final bool ble;
}

/// Aggregates every available radio into one [Transport].
///
/// Both radios carry the same frames concurrently; inbound frames are
/// deduplicated by iBFS sequence ID so a message delivered over BLE *and*
/// Wi-Fi Direct is still spoken exactly once. This is what makes the app
/// genuinely zero-infrastructure: no hotspot, no router, no pairing, no
/// host/client split — every device transmits and receives on equal terms.
///
/// Radio policy (2.4 GHz is shared between BLE and Wi-Fi on every phone, which
/// is why "Wi-Fi connected ⇒ BLE stops working" happens):
///  * BLE starts immediately — it is the low-power, fastest-to-connect path.
///  * Wi-Fi Direct is held back for [_wifiGraceMs] while BLE is still finding
///    peers, so the two radios do not fight during initial connection setup.
///  * If BLE is up but still has no peer after the grace period (exactly the
///    case when an active Wi-Fi link is starving BLE discovery), Wi-Fi Direct
///    is started so the link can still form.
///  * If BLE cannot start at all, Wi-Fi Direct starts straight away.
class MeshTransport implements Transport {
  MeshTransport({
    BleMeshTransport? ble,
    WifiDirectTransport? wifiDirect,
    CodedPhyLink? codedPhy,
    WifiAwareTransport? wifiAware,
    int? nodeId,
    this.wifiGrace = const Duration(seconds: 12),
  })  : _ble = ble ?? BleMeshTransport.instance,
        _wifiDirect = wifiDirect ?? WifiDirectTransport(),
        _codedPhy = codedPhy ?? CodedPhyLink(),
        _wifiAware = wifiAware ?? WifiAwareTransport(),
        nodeId = nodeId ?? _randomNodeId() {
    // MeshTransport owns relay now: it is the layer that can decrement the
    // envelope TTL. Leaving BLE's own relay on would forward every frame twice.
    _ble.relayEnabled = false;
  }

  /// This device's 16-bit mesh identity, used as the envelope origin.
  ///
  /// Generated per launch. It only has to be unique among phones in radio
  /// range for the length of a session, and a random ID avoids the persistent
  /// identity database that a stable ID would need.
  final int nodeId;

  /// Origin node of the most recently delivered frame, so a receipt can be
  /// addressed back to the sender instead of flooded at everyone.
  int? _lastOrigin;
  int? get lastOrigin => _lastOrigin;

  /// Hops travelled by the most recently delivered frame.
  int _lastHop = 0;
  int get lastHop => _lastHop;

  /// Frames forwarded for other nodes this session ("N hops away" metric).
  int _relayedFrames = 0;
  int get relayedFrames => _relayedFrames;

  /// Relay path of the most recently delivered frame.
  List<int> _lastPath = const <int>[];
  List<int> get lastPath => List.unmodifiable(_lastPath);

  /// Learned next hops, keyed by destination node ID.
  final Map<int, _Route> _routes = {};
  int get routeCount => _routes.length;

  /// Relay-only mode: BLE stays up, ML and Wi-Fi Direct are off.
  bool _relayMode = false;
  bool get relayMode => _relayMode;

  /// When an emergency frame was last seen/sent. Bulk traffic yields to it.
  DateTime? _emergencyUntil;
  bool get emergencyActive =>
      _emergencyUntil != null && DateTime.now().isBefore(_emergencyUntil!);

  /// Longest a bulk send waits for an emergency burst to clear.
  static const Duration _bulkMaxWait = Duration(seconds: 6);
  static const Duration _emergencyWindow = Duration(seconds: 4);

  static int _randomNodeId() {
    // 0 and 0xFFFF are reserved (invalid / broadcast).
    return Random().nextInt(0xFFFE) + 1;
  }

  final BleMeshTransport _ble;
  final WifiDirectTransport _wifiDirect;
  final CodedPhyLink _codedPhy;
  final WifiAwareTransport _wifiAware;

  /// Frames heard for other nodes while no second radio was available.
  ///
  /// This is what makes a relay useful in a gap: StoreForwardQueue only holds
  /// frames this phone authored, so a transit frame used to be dropped.
  final RelayQueue relayQueue = RelayQueue();

  /// Number of relayed frames waiting for a peer.
  int get relayPending => relayQueue.length;

  /// Peers heard advertising, with their RSSI (BLE only — Wi-Fi Direct does
  /// not expose a comparable per-peer figure here).
  List<PeerSignal> get peerSignals => [
        for (final entry in _ble.peerRssi.entries)
          PeerSignal(id: entry.key, rssi: entry.value, ble: true),
      ];

  /// How long BLE is given to find a peer before Wi-Fi Direct joins in.
  final Duration wifiGrace;

  final _controller = StreamController<Uint8List>.broadcast();
  final _linkChanges = StreamController<void>.broadcast();

  /// Cross-link dedup: iBFS sequence ID → arrival ms.
  final Map<int, int> _seen = {};
  static const int _dedupTtlMs = 120000;

  StreamSubscription? _bleSub;
  StreamSubscription? _wifiSub;
  StreamSubscription? _codedSub;
  StreamSubscription? _awareSub;
  Timer? _pollTimer;
  Timer? _healthTimer;

  /// Retry cadence when Wi-Fi Direct refuses to start (permission missing,
  /// Wi-Fi radio off, OEM restriction). The user may fix it mid-session.
  static const int _wifiDirectRetryMs = 30000;

  bool _shouldRun = false;
  int _nextWifiDirectAttemptMs = 0;
  DateTime? _startedAt;
  String _lastSignature = '';

  BleMeshTransport get ble => _ble;
  WifiDirectTransport get wifiDirect => _wifiDirect;
  CodedPhyLink get codedPhy => _codedPhy;
  WifiAwareTransport get wifiAware => _wifiAware;

  /// Fires whenever the link signature changes (peers, radio state).
  Stream<void> get linkChanged => _linkChanges.stream;

  LinkStats get stats => LinkStats(
        bleRunning: _ble.isRunning,
        bleScanning: _ble.isScanning,
        blePeers: _ble.peerCount,
        bleKnownPeers: _ble.knownPeerCount,
        bleStatus: _ble.status,
        wifiDirectRunning: _wifiDirect.isRunning,
        wifiDirectSupported: _wifiDirect.isSupported,
        wifiDirectPeers: _wifiDirect.peerCount,
        wifiDirectStatus: _wifiDirect.status,
        bleError: _ble.lastError,
        wifiDirectError: _wifiDirect.lastError,
        codedPhyRunning: _codedPhy.isRunning,
        codedPhySupported: _codedPhy.isSupported,
        codedPhyPeers: _codedPhy.peerCount,
        codedPhyStatus: _codedPhy.status,
        codedPhyActive: _codedPhy.isCoded,
        codedPhyError: _codedPhy.lastError,
        wifiAwareRunning: _wifiAware.isRunning,
        wifiAwareSupported: _wifiAware.isSupported,
        wifiAwarePeers: _wifiAware.peerCount,
        wifiAwareStatus: _wifiAware.status,
        wifiAwareError: _wifiAware.lastError,
        routeCount: _routes.length,
        relayMode: _relayMode,
      );

  @override
  Stream<Uint8List> get incoming => _controller.stream;

  /// True when at least one radio is running, so callers can distinguish
  /// "no peers yet" from "radios are off".
  @override
  bool get isConnected => stats.anyRunning;

  /// Whether a frame can actually reach another device right now.
  bool get hasPeers => stats.hasPeers;

  /// In-flight start, shared by concurrent callers.
  ///
  /// The controller starts the mesh from two places (right after the
  /// permission grant, and from an init fallback timer). Without this guard
  /// both calls run `startAdvertising()`/`discoverPeers()` at once, and the
  /// second Wi-Fi Direct discovery fails with BUSY (reason 2).
  Future<bool>? _starting;

  /// Bring both radios up. Returns `true` when at least one radio started.
  Future<bool> start() {
    if (_shouldRun && stats.anyRunning) return Future<bool>.value(true);
    return _starting ??= _startRadios().whenComplete(() => _starting = null);
  }

  Future<bool> _startRadios() async {
    _shouldRun = true;
    _startedAt ??= DateTime.now();

    _bleSub ??= _ble.incoming.listen(_onInbound);
    _wifiSub ??= _wifiDirect.incoming.listen(_onInbound);
    _codedSub ??= _codedPhy.incoming.listen(_onInbound);
    _awareSub ??= _wifiAware.incoming.listen(_onInbound);

    // Relay mode trades bandwidth for battery: BLE advertising/scanning stays
    // up, Wi-Fi Direct and model work do not.
    _ble.lowPower = _relayMode;
    if (_relayMode) await _wifiDirect.stop();

    _pollTimer ??= Timer.periodic(const Duration(seconds: 2), (_) => _emitChanges());
    _healthTimer ??=
        Timer.periodic(const Duration(seconds: 6), (_) => _healthCheck());

    final bleOk = await _ble.start();

    // Long-range BLE shares the Bluetooth radio with the 1M link, so it starts
    // alongside it rather than after a grace period: a node 200 m away must be
    // heard on the first sweep, not after the short-range link gives up.
    if (!_relayMode) unawaited(_ensureCodedPhy());

    if (!bleOk && !_relayMode) {
      // BLE refused (radio off, permission denied, unsupported): fall through
      // to Wi-Fi Direct immediately rather than leaving the user with nothing.
      // Relay mode deliberately keeps Wi-Fi off to protect battery life.
      debugPrint('MeshTransport: BLE unavailable — starting Wi-Fi Direct');
      await _ensureWifiDirect(force: true);
    }

    _emitChanges(force: true);
    return bleOk || _wifiDirect.isRunning;
  }

  /// Retry BLE if it dropped, and bring Wi-Fi Direct up once the grace
  /// period has elapsed without a BLE peer.
  Future<void> _healthCheck() async {
    if (!_shouldRun) return;

    if (!_ble.isRunning) {
      final ok = await _ble.start();
      if (ok) debugPrint('MeshTransport: BLE restarted');
    }

    if (!_relayMode && !_codedPhy.isRunning) unawaited(_ensureCodedPhy());

    final elapsed = _startedAt == null
        ? Duration.zero
        : DateTime.now().difference(_startedAt!);
    if (!_relayMode && (elapsed >= wifiGrace || !_ble.isRunning)) {
      await _ensureWifiAware();
      // Wi-Fi Aware and Wi-Fi Direct both drive the Wi-Fi radio. Only fall back
      // to Direct when Aware is genuinely not available on this handset, so the
      // two never fight over the same hardware.
      if (!_wifiAware.isSupported &&
          !_wifiAware.isRunning &&
          !_wifiDirect.isRunning) {
        await _ensureWifiDirect();
      }
    }

    _emitChanges();
  }

  /// Retry cadence for the long-range radio and Wi-Fi Aware.
  static const int _codedPhyRetryMs = 60000;
  static const int _wifiAwareRetryMs = 45000;
  int _nextCodedPhyAttemptMs = 0;
  int _nextWifiAwareAttemptMs = 0;

  /// Bring up (or retry) the LE Coded PHY link. Probing is cheap but not free,
  /// so a failed probe is retried on a slow cadence instead of every tick.
  Future<void> _ensureCodedPhy() async {
    if (_relayMode || _codedPhy.isRunning) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now < _nextCodedPhyAttemptMs) return;
    _nextCodedPhyAttemptMs = now + _codedPhyRetryMs;

    if (!await _codedPhy.probe()) {
      debugPrint('MeshTransport: LE Coded PHY not supported on this device');
      _emitChanges(force: true);
      return;
    }
    final ok = await _codedPhy.start();
    debugPrint('MeshTransport: LE Coded PHY start → $ok '
        '(${_codedPhy.status})');
    _emitChanges(force: true);
  }

  /// Bring up (or retry) a Wi-Fi Aware link.
  Future<void> _ensureWifiAware({bool force = false}) async {
    if (_relayMode || _wifiAware.isRunning) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (!force && now < _nextWifiAwareAttemptMs) return;
    _nextWifiAwareAttemptMs = now + _wifiAwareRetryMs;

    if (!await _wifiAware.probe()) {
      debugPrint('MeshTransport: Wi-Fi Aware unavailable on this device');
      _emitChanges(force: true);
      return;
    }
    final ok = await _wifiAware.start();
    debugPrint('MeshTransport: Wi-Fi Aware start → $ok '
        '(${_wifiAware.status})');
    _emitChanges(force: true);
  }

  Future<void> _ensureWifiDirect({bool force = false}) async {
    if (_relayMode) return;
    if (_wifiDirect.isRunning) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (!force && now < _nextWifiDirectAttemptMs) return;
    _nextWifiDirectAttemptMs = now + _wifiDirectRetryMs;
    final ok = await _wifiDirect.start();
    debugPrint('MeshTransport: Wi-Fi Direct start → $ok '
        '(${_wifiDirect.status})');
    _emitChanges(force: true);
  }

  /// Send on every live radio. Throws when no device is reachable so the
  /// controller can queue the frame for store-and-forward delivery.
  @override
  Future<int> send(Uint8List frame) {
    if (_isEmergency(frame)) _noteEmergency();
    return sendTo(frame, kBroadcastNode);
  }

  /// Bulk traffic (ledger gossip, voice chunks, breadcrumbs, time sync) yields
  /// while an emergency is on the air. Waiting is bounded: a stuck emergency
  /// flag must never block a camp update forever.
  Future<int> sendBulk(Uint8List frame) async {
    final deadline = DateTime.now().add(_bulkMaxWait);
    while (emergencyActive && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    return sendTo(frame, kBroadcastNode);
  }

  /// Switch to/from relay-only mode. The radios are restarted by the caller
  /// when this changes; the flag itself only affects policy.
  Future<void> setRelayMode(bool enabled) async {
    if (_relayMode == enabled) return;
    _relayMode = enabled;
    _ble.lowPower = enabled;
    if (enabled) {
      await _wifiDirect.stop();
      await _wifiAware.stop();
      await _codedPhy.stop();
    } else {
      _startedAt = DateTime.now();
      _nextWifiDirectAttemptMs = 0;
      _nextWifiAwareAttemptMs = 0;
      _nextCodedPhyAttemptMs = 0;
      unawaited(_ensureCodedPhy());
      unawaited(_ensureWifiAware(force: true));
    }
    _emitChanges(force: true);
  }

  /// Send [frame] addressed to one mesh node (targeted receipt or assignment).
  /// Falls back to flood when no route has been learned yet; addressing is
  /// enforced by the envelope, not by the link layer.
  Future<int> sendTo(Uint8List frame, int destination) async {
    // Mark locally originated frames so the mesh does not re-deliver our own
    // packet when it echoes back through a peer. The dedup key is the inner
    // iBFS sequence ID, which is why the envelope is added *after* this.
    _ble.markOriginated(frame);
    _remember(frame);

    final route = _routes[destination];
    final wire = encodeMeshEnvelope(
      frame: frame,
      origin: nodeId,
      dest: destination,
      nextHop: route?.nextHop ?? kFloodNextHop,
    );

    var fanout = 0;
    final failures = <String>[];

    if (_ble.isRunning) {
      try {
        fanout += await _ble.send(wire);
      } catch (e) {
        failures.add('BLE: $e');
      }
    }

    if (_wifiDirect.isRunning) {
      try {
        fanout += await _wifiDirect.send(wire);
      } catch (e) {
        failures.add('Wi-Fi Direct: $e');
      }
    }

    if (_codedPhy.isRunning) {
      try {
        fanout += await _codedPhy.send(wire);
      } on StateError {
        // No long-range peer yet: not a failure, just an idle radio.
      } catch (e) {
        failures.add('Coded PHY: $e');
      }
    }

    if (_wifiAware.isRunning) {
      try {
        fanout += await _wifiAware.send(wire);
      } catch (e) {
        failures.add('Wi-Fi Aware: $e');
      }
    }

    if (fanout > 0) return fanout;

    if (!stats.anyRunning) {
      throw StateError('No radio is running — Bluetooth and Wi-Fi Direct are '
          'both unavailable');
    }
    throw StateError(failures.isEmpty
        ? 'No peer in range yet'
        : failures.join(' · '));
  }

  void _onInbound(Uint8List bytes) {
    // ── Mesh v2 ──
    final envelope = decodeMeshEnvelope(bytes);
    if (envelope != null) {
      _learnRoute(envelope);
      if (_isEmergency(envelope.frame)) _noteEmergency();

      // Dedup on the inner frame's sequence ID: the same message arriving over
      // BLE and Wi-Fi Direct, or echoing back through a relay, is one message.
      if (!_isNewFrame(envelope.frame)) return;

      final forMe = envelope.isBroadcast || envelope.dest == nodeId;
      if (forMe) {
        _lastOrigin = envelope.origin;
        _lastHop = envelope.hop;
        _lastPath = envelope.path;
        if (!_controller.isClosed) _controller.add(envelope.frame);
      }

      // Relay regardless of whether this frame was for us: a broadcast must
      // reach nodes two hops away, and a targeted frame may need us as a
      // stepping stone. A learned next hop narrows that to one neighbour.
      if (!envelope.shouldRelayAt(nodeId)) return;
      final route = _routes[envelope.dest];
      final next = envelope.forwarded(
        relay: nodeId,
        nextHop: route?.nextHop ?? kFloodNextHop,
      );
      if (next != null) {
        _relay(encodeMeshEnvelope(
          frame: next.frame,
          origin: next.origin,
          dest: next.dest,
          ttl: next.ttl,
          hop: next.hop,
          nextHop: next.nextHop,
          path: next.path,
        ));
      }
      return;
    }

    // ── Legacy raw iBFS frame (v1 peer) ──
    if (bytes.length < 8) return;
    if (!_isNewFrame(bytes)) return;
    if (!_controller.isClosed) _controller.add(bytes);
    _relay(bytes);
  }

  /// Forward a frame on every live radio, ignoring failures.
  ///
  /// Best-effort by design: a relay that cannot reach a second radio must not
  /// throw into the receive path and drop the frame being processed.
  void _relay(Uint8List wire) {
    _relayedFrames++;
    unawaited(_sendWire(wire).then((fanout) {
      // No second radio / no peer: keep somebody else's frame for later
      // instead of dropping it, and retry when a link appears.
      if (fanout == 0) relayQueue.enqueue(wire);
    }));
  }

  /// Send one already-encoded wire frame on every live radio.
  Future<int> _sendWire(Uint8List wire) async {
    var fanout = 0;
    if (_ble.isRunning) {
      try {
        fanout += await _ble.send(wire);
      } catch (e) {
        debugPrint('MeshTransport: BLE relay failed: $e');
      }
    }
    if (_wifiDirect.isRunning) {
      try {
        fanout += await _wifiDirect.send(wire);
      } catch (e) {
        debugPrint('MeshTransport: Wi-Fi Direct relay failed: $e');
      }
    }
    if (_codedPhy.isRunning) {
      try {
        fanout += await _codedPhy.send(wire);
      } catch (e) {
        debugPrint('MeshTransport: Coded PHY relay failed: $e');
      }
    }
    if (_wifiAware.isRunning) {
      try {
        fanout += await _wifiAware.send(wire);
      } catch (e) {
        debugPrint('MeshTransport: Wi-Fi Aware relay failed: $e');
      }
    }
    return fanout;
  }

  bool _flushingRelay = false;

  Future<void> _flushRelayQueue() async {
    if (_flushingRelay || relayQueue.isEmpty || !stats.hasPeers) return;
    _flushingRelay = true;
    try {
      await relayQueue.flush(_sendWire);
    } finally {
      _flushingRelay = false;
    }
  }

  /// Cross-link dedup — the same frame can arrive over BLE *and* Wi-Fi Direct,
  /// and relays can echo it back. Each sequence ID is admitted once.
  bool _isNewFrame(Uint8List frame) {
    if (frame[0] != 0x49 || frame[1] != 0x54) return false;
    final id = ByteData.sublistView(frame).getUint32(4, Endian.big);
    final now = DateTime.now().millisecondsSinceEpoch;
    if (_seen.containsKey(id)) return false;
    if (_seen.length > 512) {
      _seen.removeWhere((_, t) => now - t > _dedupTtlMs);
      if (_seen.length > 512) _seen.clear();
    }
    _seen[id] = now;
    return true;
  }

  void _remember(Uint8List frame) {
    if (frame.length < 8) return;
    final id = ByteData.sublistView(frame).getUint32(4, Endian.big);
    _seen[id] = DateTime.now().millisecondsSinceEpoch;
  }

  /// Learn/replace the route to the frame's origin from the relay that
  /// delivered it. A shorter hop count wins; a stalled route is refreshed.
  void _learnRoute(MeshEnvelope envelope) {
    final origin = envelope.origin;
    if (origin == nodeId) return;
    final via = envelope.path.isNotEmpty
        ? envelope.path.last
        : (envelope.nextHop != 0 ? envelope.nextHop : null);
    if (via == null || via == origin) return;
    final existing = _routes[origin];
    final now = DateTime.now();
    if (existing != null &&
        envelope.hop > existing.hops &&
        now.difference(existing.updatedAt) < const Duration(minutes: 2)) {
      return;
    }
    _routes[origin] = _Route(via, envelope.hop, now);
    if (_routes.length > 64) {
      // Drop the least recently refreshed destinations.
      final oldest = _routes.entries.reduce(
        (a, b) => a.value.updatedAt.isBefore(b.value.updatedAt) ? a : b,
      );
      _routes.remove(oldest.key);
    }
  }

  static bool _isEmergency(Uint8List frame) {
    if (frame.length < 4) return false;
    if (frame[0] != 0x49 || frame[1] != 0x54) return false;
    return ((frame[3] >> 4) & 0x0F) == 0xF;
  }

  void _noteEmergency() {
    _emergencyUntil = DateTime.now().add(_emergencyWindow);
  }

  void _emitChanges({bool force = false}) {
    final signature = stats.signature;
    if (!force && signature == _lastSignature) return;
    _lastSignature = signature;
    if (stats.hasPeers && relayQueue.length > 0) {
      unawaited(_flushRelayQueue());
    }
    if (!_linkChanges.isClosed) _linkChanges.add(null);
  }

  /// Tear down both radios.
  @override
  Future<void> disconnect() async {
    _shouldRun = false;
    _pollTimer?.cancel();
    _healthTimer?.cancel();
    _pollTimer = null;
    _healthTimer = null;

    await _bleSub?.cancel();
    await _wifiSub?.cancel();
    await _codedSub?.cancel();
    await _awareSub?.cancel();
    _bleSub = null;
    _wifiSub = null;
    _codedSub = null;
    _awareSub = null;

    await _wifiAware.stop();
    await _codedPhy.stop();
    await _wifiDirect.stop();
    await _ble.stop();
    _nextWifiDirectAttemptMs = 0;

    if (!_linkChanges.isClosed) _linkChanges.add(null);
  }

  Future<void> dispose() async {
    await disconnect();
    await _wifiDirect.dispose();
    await _wifiAware.dispose();
    await _codedPhy.dispose();
    await _controller.close();
    await _linkChanges.close();
  }
}

class _Route {
  _Route(this.nextHop, this.hops, this.updatedAt);

  final int nextHop;
  final int hops;
  final DateTime updatedAt;
}
