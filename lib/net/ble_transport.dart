import 'dart:async';

import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:flutter/foundation.dart';

import 'fragmentation.dart';

/// BLE GATT mesh transport (NETWORK_PROTOCOL.md §2).
///
/// Every device runs BOTH roles at the same time:
///  - Peripheral: advertises the Sahara service and accepts writes/notifies.
///  - Central: scans for other Sahara nodes, connects and subscribes.
///
/// Because both roles are always active there is no host/client split, so
/// PTT works in both directions, with no pairing and no hotspot. A GATT
/// connection is not a bond — Android never shows a pairing dialog.
///
/// Three failure modes that used to break field use are handled here:
///
///  1. **Frame corruption.** Frames larger than one ATT payload are split into
///     [FrameSplitter] chunks and rebuilt by [FrameReassembler] before reaching
///     the iBFS decoder. Feeding raw chunks to the decoder was the cause of
///     `[Corrupt frame dropped] IbfDecodeError: CRC mismatch`.
///  2. **Dead scan sessions.** Android silently stops delivering scan results
///     after a while (and deprioritises BLE while Wi-Fi is busy), which made the
///     peer count stick at "offline". The scan session is rotated on a timer.
///  3. **Lost links that never re-form.** Peers seen in advertisements are
///     remembered and re-connected with backoff instead of waiting for Android
///     to re-report them (it caches scan results).
class BleMeshTransport {
  BleMeshTransport._();

  static final BleMeshTransport instance = BleMeshTransport._();

  // ── Sahara GATT identifiers (custom 128-bit UUIDs) ──────────────
  static final UUID serviceUuid =
      UUID.fromString('8f1d3a50-6f2c-4c1e-9b7a-5a2e9d0c1a10');
  static final UUID frameCharUuid =
      UUID.fromString('8f1d3a50-6f2c-4c1e-9b7a-5a2e9d0c1a11');

  /// Locally generated frame IDs are cached this long for deduplication.
  static const int _dedupTtlMs = 120000;

  /// Rotate the scan session this often (Android scan results go stale).
  static const int _scanRotateMs = 15000;

  /// Retry known-but-disconnected peers on this cadence.
  static const int _retryMs = 6000;

  /// Forget a peer that has not advertised for this long.
  static const int _peerTtlMs = 90000;

  /// Concurrent GATT connections are capped — Android stacks typically start
  /// failing with status 133 beyond ~4–7, and each one costs radio airtime.
  static const int _maxPeers = 4;

  /// iBFS magic bytes, used to reject non-protocol payloads.
  static const int _ibfsMagic0 = 0x49; // 'I'
  static const int _ibfsMagic1 = 0x54; // 'T'

  /// Local name carried in the advertisement's scan response. Used both for
  /// advertising and as a discovery fallback (see [_onDiscovered]).
  static const String advertisedName = 'Sahara';

  final PeripheralManager _peripheral = PeripheralManager();
  final CentralManager _central = CentralManager();

  final _controller = StreamController<Uint8List>.broadcast();

  /// Peers we hold a GATT connection to (we are the central).
  final Map<String, Peripheral> _connected = {};
  final Map<String, GATTCharacteristic> _peerChars = {};
  final Map<String, int> _peerWritePayload = {};

  /// Centrals connected to us (we are the peripheral).
  final Map<String, Central> _subscribedCentrals = {};
  final Map<String, int> _notifyPayload = {};

  /// Peers seen advertising the Sahara service, for reconnect retries.
  /// Whether this transport relays received frames itself.
  /// [MeshTransport] disables it so routing lives in one place.
  bool relayEnabled = true;

  /// Relay-only power policy: keep advertising, but scan less often so a
  /// spare phone can sit as a repeater for hours.
  bool lowPower = false;

  int _lastRotateMs = 0;

  final Map<String, _PeerRecord> _knownPeers = {};

  /// In-flight connection attempts, keyed by peer.
  final Set<String> _connecting = {};

  /// Peers whose GATT discovery/subscribe is in progress.
  final Set<String> _subscribing = {};

  /// Dedup cache: iBFS sequence ID → arrival ms.
  final Map<int, int> _seenIds = {};

  final FrameSplitter _splitter = FrameSplitter();
  final FrameReassembler _reassembler = FrameReassembler();

  GATTCharacteristic? _frameChar;
  bool _running = false;
  bool _scanning = false;
  Timer? _scanTimer;
  Timer? _retryTimer;

  StreamSubscription? _subDiscovered;
  StreamSubscription? _subCentralConn;
  StreamSubscription? _subNotified;
  StreamSubscription? _subWrite;
  StreamSubscription? _subNotifyState;
  StreamSubscription? _subPeripheralConn;

  /// Inbound (and relayed) iBFS frames from the mesh.
  Stream<Uint8List> get incoming => _controller.stream;

  /// Whether the BLE mesh is currently running.
  bool get isRunning => _running;

  /// Number of peers we can currently exchange frames with.
  int get peerCount => _connected.length + _subscribedCentrals.length;

  /// Number of nodes recently seen advertising, connected or not.
  int get knownPeerCount =>
      _knownPeers.length + _connected.length + _subscribedCentrals.length;

  /// Last RSSI reported for each known peer, for coarse homing.
  Map<String, int> get peerRssi => {
        for (final entry in _knownPeers.entries) entry.key: entry.value.rssi,
      };

  /// Whether the central-role scan session is active.
  bool get isScanning => _scanning;

  /// Why the last start attempt failed, if it did. Surfaced in the UI so
  /// "offline" is never a dead end.
  String? get lastError => _lastError;
  String? _lastError;

  /// Human-readable link state for the UI.
  String get status {
    if (!_running) return 'off';
    final peers = peerCount;
    if (peers > 0) return '$peers peer${peers == 1 ? '' : 's'}';
    return _scanning ? 'scanning' : 'idle';
  }

  static String _key(UUID uuid) => uuid.value.join(',');

  /// Start advertising + scanning.
  ///
  /// Ordering matters (this was the 'Bluetooth unavailable' bug):
  /// 1. `authorize()` shows the Android runtime permission dialog and must run
  ///    BEFORE any state check — the state reads `unauthorized` until the user
  ///    grants the Bluetooth permissions, so a naive
  ///    `state != poweredOn → return false` always failed here.
  /// 2. Wait (briefly) for the state stream to settle at `poweredOn`.
  /// 3. Only then publish the GATT service, advertise, and scan.
  Future<bool> start() async {
    if (_running) return true;
    try {
      // ── Step 1: request permissions (both roles) ──
      final centralOk = await _central.authorize();
      if (!centralOk) {
        _lastError = 'Bluetooth permission denied';
        debugPrint('BleMesh: central authorize denied');
        return false;
      }
      try {
        await _peripheral.authorize();
      } catch (e) {
        debugPrint('BleMesh: peripheral authorize failed: $e');
      }

      // ── Step 2: wait for the radio to be powered on ──
      if (!await _waitForPoweredOn()) return false;
      _lastError = null;

      // ── Step 3: peripheral role — publish service & advertise ──
      _frameChar = GATTCharacteristic.mutable(
        uuid: frameCharUuid,
        properties: [
          GATTCharacteristicProperty.read,
          GATTCharacteristicProperty.write,
          GATTCharacteristicProperty.writeWithoutResponse,
          GATTCharacteristicProperty.notify,
        ],
        permissions: [
          GATTCharacteristicPermission.read,
          GATTCharacteristicPermission.write,
        ],
        descriptors: [],
      );
      final service = GATTService(
        uuid: serviceUuid,
        isPrimary: true,
        includedServices: [],
        characteristics: [_frameChar!],
      );
      await _peripheral.addService(service);

      await _peripheral.startAdvertising(Advertisement(
        name: advertisedName,
        serviceUUIDs: [serviceUuid],
      ));

      // ── Event wiring ──
      _subDiscovered = _central.discovered.listen(_onDiscovered);
      _subCentralConn =
          _central.connectionStateChanged.listen(_onCentralConnChanged);
      _subNotified = _central.characteristicNotified.listen(_onNotified);
      _subWrite =
          _peripheral.characteristicWriteRequested.listen(_onWriteRequested);
      _subPeripheralConn = _peripheral.connectionStateChanged
          .listen(_onPeripheralConnChanged);
      _subNotifyState =
          _peripheral.characteristicNotifyStateChanged.listen(_onNotifyState);

      // ── Central role: scan without a hardware UUID filter ──
      // Hardware 128-bit UUID filtering is dropped by several Android BLE
      // drivers, so discovery is unfiltered and filtered in software in
      // _onDiscovered. Advertising still carries the service UUID, so peers
      // can identify us.
      await _startScan();

      _scanTimer = Timer.periodic(
        const Duration(milliseconds: _scanRotateMs),
        (_) => _rotateScan(),
      );
      _retryTimer = Timer.periodic(
        const Duration(milliseconds: _retryMs),
        (_) => _retryPeers(),
      );

      _running = true;
      debugPrint('BleMesh: started (advertising + scanning)');
      return true;
    } catch (e) {
      _lastError = e.toString();
      debugPrint('BleMeshTransport.start failed: $e');
      await stop();
      return false;
    }
  }

  /// Poll the state (refreshes it on Android) and wait up to ~4 s for
  /// `poweredOn`. Fails fast with a precise reason on other states.
  Future<bool> _waitForPoweredOn() async {
    const maxWaits = 8; // 8 × 500 ms = 4 s
    for (var i = 0; i < maxWaits; i++) {
      final state = _central.state;
      switch (state) {
        case BluetoothLowEnergyState.poweredOn:
          return true;
        case BluetoothLowEnergyState.unsupported:
          _lastError = 'This device has no Bluetooth LE radio';
          debugPrint('BleMesh: BLE unsupported on this device');
          return false;
        case BluetoothLowEnergyState.unauthorized:
          _lastError = 'Bluetooth permission not granted';
          debugPrint('BleMesh: Bluetooth permissions not granted');
          return false;
        case BluetoothLowEnergyState.poweredOff:
          _lastError = 'Bluetooth is switched off — turn it on';
          debugPrint('BleMesh: Bluetooth is powered off');
          return false;
        case BluetoothLowEnergyState.unknown:
          // State still settling — wait and retry.
          await Future<void>.delayed(const Duration(milliseconds: 500));
      }
    }
    _lastError = 'Bluetooth did not become ready — check it is switched on';
    debugPrint('BleMesh: Bluetooth state did not settle');
    return false;
  }

  Future<void> _startScan() async {
    try {
      await _central.startDiscovery();
      _scanning = true;
    } catch (e) {
      _scanning = false;
      debugPrint('BleMesh: startDiscovery failed: $e');
    }
  }

  /// Android scan sessions stop delivering results after a while (and Wi-Fi
  /// activity can starve them), so the session is restarted periodically.
  /// Connections are left untouched — only the scan is cycled.
  Future<void> _rotateScan() async {
    if (!_running) return;
    // Enough peers for the relay to be healthy; don't churn the radio.
    if (peerCount >= _maxPeers) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (lowPower && now - _lastRotateMs < 30000) return;
    _lastRotateMs = now;
    try {
      await _central.stopDiscovery();
    } catch (_) {}
    _scanning = false;
    await Future<void>.delayed(const Duration(milliseconds: 350));
    if (!_running) return;
    await _startScan();
    // Force a fresh attempt at any peer that is known but not connected.
    _retryPeers();
  }

  /// Reconnect peers we have seen advertising but are not connected to.
  void _retryPeers() {
    if (!_running) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    _knownPeers.removeWhere((_, r) => now - r.lastSeenMs > _peerTtlMs);
    if (_connecting.length + _connected.length >= _maxPeers) return;

    for (final record in _knownPeers.values.toList()) {
      final key = record.key;
      if (_connected.containsKey(key) || _connecting.contains(key)) continue;
      if (now - record.lastAttemptMs < (lowPower ? 20000 : _retryMs)) {
        continue;
      }
      record.lastAttemptMs = now;
      _connectTo(record.peripheral, key);
    }
  }

  /// Send an iBFS frame: write to every connected peer (they relay) and notify
  /// directly-subscribed centrals.
  ///
  /// [excludePeer] / [excludeCentral] are used by the relay path so a frame is
  /// never echoed back to the peer it came from.
  Future<int> send(
    Uint8List frame, {
    String? excludePeer,
    String? excludeCentral,
  }) async {
    if (!_running) throw StateError('BLE mesh not started');
    var fanout = 0;

    // ── Central role: write to the peripherals we are connected to ──
    for (final entry in List.of(_connected.entries)) {
      if (excludePeer != null && entry.key == excludePeer) continue;
      final char = _peerChars[entry.key];
      if (char == null) continue;
      final payload = _peerWritePayload[entry.key] ?? FrameFragmenter.minAttPayload;
      try {
        for (final chunk in _splitter.split(frame, payload)) {
          await _central.writeCharacteristic(
            entry.value,
            char,
            value: chunk,
            type: GATTCharacteristicWriteType.withResponse,
          );
        }
        fanout++;
      } catch (e) {
        debugPrint('BleMesh: write to ${entry.key} failed: $e');
      }
    }

    // ── Peripheral role: notify subscribed centrals ──
    for (final entry in List.of(_subscribedCentrals.entries)) {
      if (excludeCentral != null && entry.key == excludeCentral) continue;
      final char = _frameChar;
      if (char == null) continue;
      final payload = await _notifyPayloadFor(entry.key, entry.value);
      try {
        for (final chunk in _splitter.split(frame, payload)) {
          await _peripheral.notifyCharacteristic(
            entry.value,
            char,
            value: chunk,
          );
        }
        fanout++;
      } catch (e) {
        debugPrint('BleMesh: notify ${entry.key} failed: $e');
      }
    }

    return fanout;
  }

  /// ATT notify payload for a central, negotiated once and cached. Without
  /// this, a frame bigger than MTU−3 is silently truncated by the OS stack.
  Future<int> _notifyPayloadFor(String key, Central central) async {
    final cached = _notifyPayload[key];
    if (cached != null) return cached;
    var payload = FrameFragmenter.minAttPayload;
    try {
      final max = await _peripheral.getMaximumNotifyLength(central);
      if (max > FrameFragmenter.headerLen) payload = max;
    } catch (e) {
      debugPrint('BleMesh: getMaximumNotifyLength failed: $e');
    }
    _notifyPayload[key] = payload;
    return payload;
  }

  void _onDiscovered(DiscoveredEventArgs args) {
    final advertisement = args.advertisement;
    final hasService =
        advertisement.serviceUUIDs.contains(serviceUuid) ||
            advertisement.serviceData.containsKey(serviceUuid);

    // Several Android stacks do not surface 128-bit service UUIDs in
    // `ScanRecord.getServiceUuids()` — the bytes arrive but are never parsed
    // into the list — so a strict UUID check silently rejects a real Sahara
    // node and the mesh sits at "searching, 0 peers" forever. The peer also
    // advertises its local name in the scan response, so accept either signal.
    final hasName = advertisement.name == advertisedName;
    if (!hasService && !hasName) {
      debugPrint('BleMesh: ignoring ${advertisement.name ?? 'unnamed'} '
          '(${args.peripheral.uuid.value.join(',')}) — not an Sahara node');
      return;
    }
    debugPrint('BleMesh: found Sahara node via '
        '${hasService ? 'service UUID' : 'advertised name'} '
        '(rssi ${args.rssi})');

    final key = _key(args.peripheral.uuid);
    final now = DateTime.now().millisecondsSinceEpoch;
    final record = _knownPeers.putIfAbsent(
      key,
      () => _PeerRecord(key, args.peripheral),
    );
    record.peripheral = args.peripheral;
    record.lastSeenMs = now;
    record.rssi = args.rssi;

    if (_connected.containsKey(key) || _connecting.contains(key)) return;
    if (_connecting.length + _connected.length >= _maxPeers) return;
    record.lastAttemptMs = now;
    _connectTo(args.peripheral, key);
  }

  void _connectTo(Peripheral peripheral, String key) {
    if (!_connecting.add(key)) return;
    debugPrint('BleMesh: connecting to $key…');
    _central.connect(peripheral).then((_) {
      _connecting.remove(key);
      // Android normally reports the connected state through the stream, but
      // start using the link immediately so a missed stream event cannot
      // leave the peer permanently "connected but unusable".
      if (_running && !_connected.containsKey(key) && !_subscribing.contains(key)) {
        _connected[key] = peripheral;
        _subscribeAndNegotiate(peripheral, key);
      }
    }, onError: (Object e) {
      _connecting.remove(key);
      debugPrint('BleMesh: connect to $key failed: $e');
    });
  }

  void _onCentralConnChanged(PeripheralConnectionStateChangedEventArgs args) {
    final key = _key(args.peripheral.uuid);
    _connecting.remove(key);
    if (args.state == ConnectionState.connected) {
      debugPrint('BleMesh: connected to peer $key');
      _connected[key] = args.peripheral;
      _subscribeAndNegotiate(args.peripheral, key);
    } else {
      debugPrint('BleMesh: peer $key disconnected');
      _connected.remove(key);
      _peerChars.remove(key);
      _peerWritePayload.remove(key);
      _subscribing.remove(key);
      _reassembler.reset();
      // Try again shortly — a dropped link should re-form on its own.
      _knownPeers[key]?.lastAttemptMs = 0;
    }
  }

  void _onPeripheralConnChanged(CentralConnectionStateChangedEventArgs args) {
    final key = _key(args.central.uuid);
    if (args.state == ConnectionState.connected) return;
    _subscribedCentrals.remove(key);
    _notifyPayload.remove(key);
    debugPrint('BleMesh: central $key disconnected');
  }

  Future<void> _subscribeAndNegotiate(Peripheral peripheral, String key) async {
    if (!_subscribing.add(key)) return;
    try {
      // Request the largest ATT MTU. Android 14+ fixes this at 517 for the
      // first client, so failures are expected and harmless.
      try {
        await _central.requestMTU(peripheral, mtu: 517);
      } catch (e) {
        debugPrint('BleMesh: MTU negotiation failed for $key: $e');
      }

      var payload = FrameFragmenter.minAttPayload;
      try {
        final max = await _central.getMaximumWriteLength(
          peripheral,
          type: GATTCharacteristicWriteType.withResponse,
        );
        if (max > FrameFragmenter.headerLen) payload = max;
      } catch (e) {
        debugPrint('BleMesh: getMaximumWriteLength failed for $key: $e');
      }
      _peerWritePayload[key] = payload;
      debugPrint('BleMesh: write payload for $key = $payload bytes');

      final services = await _central.discoverGATT(peripheral);
      for (final service in services) {
        if (service.uuid.value.join(',') != serviceUuid.value.join(',')) continue;
        for (final char in service.characteristics) {
          if (char.uuid.value.join(',') != frameCharUuid.value.join(',')) {
            continue;
          }
          _peerChars[key] = char;
          await _central.setCharacteristicNotifyState(
            peripheral,
            char,
            state: true,
          );
          debugPrint('BleMesh: subscribed to $key');
        }
      }
    } catch (e) {
      debugPrint('BleMesh: subscribe to $key failed: $e');
    } finally {
      _subscribing.remove(key);
    }
  }

  void _onNotified(GATTCharacteristicNotifiedEventArgs args) {
    if (args.characteristic.uuid.value.join(',') !=
        frameCharUuid.value.join(',')) {
      return;
    }
    _ingestChunk(
      'p/${args.peripheral.uuid.value.join(',')}',
      args.value,
      excludePeer: _key(args.peripheral.uuid),
    );
  }

  Future<void> _onWriteRequested(
    GATTCharacteristicWriteRequestedEventArgs args,
  ) async {
    final isFrameChar = args.characteristic.uuid.value.join(',') ==
        frameCharUuid.value.join(',');
    // Acknowledge first: the remote side is blocked on this ATT response.
    try {
      await _peripheral.respondWriteRequest(args.request);
    } catch (e) {
      debugPrint('BleMesh: write response failed: $e');
    }
    if (!isFrameChar) return;
    _ingestChunk(
      'c/${args.central.uuid.value.join(',')}',
      args.request.value,
      excludeCentral: _key(args.central.uuid),
    );
  }

  void _onNotifyState(GATTCharacteristicNotifyStateChangedEventArgs args) {
    if (args.characteristic.uuid.value.join(',') !=
        frameCharUuid.value.join(',')) {
      return;
    }
    final key = _key(args.central.uuid);
    if (args.state) {
      _subscribedCentrals[key] = args.central;
    } else {
      _subscribedCentrals.remove(key);
      _notifyPayload.remove(key);
    }
  }

  /// Reassemble chunks, then hand complete frames to [_ingest].
  void _ingestChunk(
    String source,
    Uint8List chunk, {
    String? excludePeer,
    String? excludeCentral,
  }) {
    final frame = _reassembler.accept(source, chunk);
    if (frame == null) return;
    _ingest(frame, excludePeer: excludePeer, excludeCentral: excludeCentral);
  }

  /// Dedup + relay. Frames are identified by the uint32 sequence ID (bytes 4–7
  /// of the iBFS header). Each ID is delivered to the app once and relayed once
  /// to all other peers — flooding without loops.
  void _ingest(
    Uint8List frame, {
    String? excludePeer,
    String? excludeCentral,
  }) {
    if (frame.length < 8) return;

    // Mesh-v2 mode: the bytes are an envelope (magic "MS"), so the iBFS header
    // is 9 bytes in. This layer must NOT inspect the inner frame — MeshTransport
    // unwraps it, dedups on the inner sequence ID and relays it with the TTL.
    // Filtering on the iBFS magic here silently dropped every enveloped frame.
    if (!relayEnabled) {
      if (!_controller.isClosed) _controller.add(frame);
      return;
    }

    if (frame[0] != _ibfsMagic0 || frame[1] != _ibfsMagic1) return;

    final id = ByteData.sublistView(frame).getUint32(4, Endian.big);
    final now = DateTime.now().millisecondsSinceEpoch;
    if (_seenIds.containsKey(id)) return;
    if (_seenIds.length > 512) {
      _seenIds.removeWhere((_, t) => now - t > _dedupTtlMs);
      if (_seenIds.length > 512) _seenIds.clear();
    }
    _seenIds[id] = now;

    if (!_controller.isClosed) _controller.add(frame);

    // Relay is owned by MeshTransport when the mesh-v2 envelope is in use:
    // it is the only layer that can decrement the TTL, and relaying both here
    // and there would duplicate every hop. Raw-frame mode (direct use of this
    // class in tests or by a v1-only build) still relays.
    if (!relayEnabled) return;
    send(
      frame,
      excludePeer: excludePeer,
      excludeCentral: excludeCentral,
    ).then((_) {}, onError: (Object e) {
      debugPrint('BleMesh: relay failed: $e');
    });
  }

  /// Mark a locally originated frame ID as seen so it is not re-delivered when
  /// it echoes back through the mesh.
  void markOriginated(Uint8List frame) {
    if (frame.length < 8) return;
    final id = ByteData.sublistView(frame).getUint32(4, Endian.big);
    _seenIds[id] = DateTime.now().millisecondsSinceEpoch;
  }

  /// Stop the mesh and release the radios.
  Future<void> stop() async {
    _running = false;
    _scanning = false;
    _scanTimer?.cancel();
    _retryTimer?.cancel();
    _scanTimer = null;
    _retryTimer = null;

    try {
      await _central.stopDiscovery();
    } catch (_) {}
    for (final p in List.of(_connected.values)) {
      try {
        await _central.disconnect(p);
      } catch (_) {}
    }
    _connected.clear();
    _connecting.clear();
    _subscribing.clear();
    _peerChars.clear();
    _peerWritePayload.clear();
    _subscribedCentrals.clear();
    _notifyPayload.clear();
    _knownPeers.clear();
    _reassembler.reset();
    try {
      await _peripheral.stopAdvertising();
    } catch (_) {}
    try {
      await _peripheral.removeAllServices();
    } catch (_) {}

    await _subDiscovered?.cancel();
    await _subCentralConn?.cancel();
    await _subNotified?.cancel();
    await _subWrite?.cancel();
    await _subPeripheralConn?.cancel();
    await _subNotifyState?.cancel();
    _subDiscovered = null;
    _subCentralConn = null;
    _subNotified = null;
    _subWrite = null;
    _subPeripheralConn = null;
    _subNotifyState = null;
    _frameChar = null;
  }

  /// Tear down completely.
  Future<void> dispose() async {
    await stop();
    await _controller.close();
  }
}

/// A peer remembered from its advertisement, so a dropped link can be retried
/// without relying on Android re-reporting the device (it caches scan results).
class _PeerRecord {
  _PeerRecord(this.key, this.peripheral);

  final String key;
  Peripheral peripheral;
  int lastSeenMs = DateTime.now().millisecondsSinceEpoch;
  int lastAttemptMs = 0;

  /// Last RSSI from the advertisement, in dBm (coarse proximity only).
  int rssi = -127;
}
