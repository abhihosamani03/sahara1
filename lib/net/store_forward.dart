import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:shared_preferences/shared_preferences.dart';

import 'transport.dart';

/// Store-and-forward queue — ADDITIONAL_FEATURES.md §3.
///
/// When no peer is reachable, messages are queued locally (with their Sequence
/// ID for dedup) and auto-delivered on reconnect.
///
/// A queue that only ever grows is worse than no queue: in a long outage it
/// fills the disk, and the first thing it replays on reconnect is the oldest,
/// least useful message. This implementation therefore applies three rules:
///
///  * **Expiry** — an entry older than [maxAge] is dropped. A distress call
///    from six hours ago is history, not a live alert.
///  * **Priority** — emergency frames go out first, then high, then routine;
///    within a priority the oldest goes first (FIFO).
///  * **Size cap** — at most [maxEntries] entries, dropping the lowest
///    priority (oldest first) when full.
///
/// [removeBySequenceId] is called when a delivery receipt arrives, so a frame
/// that reached a peer leaves the queue instead of being re-sent.
class StoreForwardQueue {
  final Transport _transport;
  final List<_QueuedFrame> _queue = [];
  bool _processing = false;
  Timer? _timer;

  /// How long a queued message stays useful, in hours.
  final Duration maxAge;

  /// Hard cap on queued messages.
  final int maxEntries;

  /// Injected clock, so expiry is testable without waiting six hours.
  final DateTime Function() _now;

  static const _prefsKey = 'itantra_queue';
  static const Duration _flushInterval = Duration(seconds: 5);

  StoreForwardQueue(
    this._transport, {
    this.maxAge = const Duration(hours: 6),
    this.maxEntries = 100,
    DateTime Function()? clock,
    bool startTimer = true,
  }) : _now = clock ?? DateTime.now {
    _loadFromDisk();
    if (startTimer) {
      _timer = Timer.periodic(_flushInterval, (_) => _tryFlush());
    }
  }

  /// Queue a frame for later delivery. Returns the number of queued messages.
  int enqueue(Uint8List frame, {int? sequenceId}) {
    final entry = _QueuedFrame(
      frame: frame,
      sequenceId: sequenceId ?? _sequenceIdOf(frame),
      priority: _priorityOf(frame),
      queuedAt: _now(),
    );
    _queue.add(entry);
    _purgeExpired();
    _trim();
    _persistToDisk();
    _tryFlush();
    return _queue.length;
  }

  /// Number of queued messages.
  int get pendingCount => _queue.length;

  /// Whether any messages are queued.
  bool get hasPending => _queue.isNotEmpty;

  /// All queued entries (for UI display), in the order they will be sent.
  List<QueuedFrameInfo> get pending =>
      _orderedForFlush().map(QueuedFrameInfo._from).toList();

  /// Send everything once, right now. Public so a reconnect handler (or a
  /// test) does not have to wait for the 5-second tick.
  ///
  /// Only one flush runs at a time. Without this lock, the timer tick, the
  /// enqueue path and a reconnect can each enter the loop and remove the same
  /// entry twice — which is a range error, not a duplicate message.
  Future<void> flushNow() async {
    if (_processing) return;
    if (!_transport.isConnected || _queue.isEmpty) return;
    _processing = true;
    try {
      _purgeExpired();
      while (_queue.isNotEmpty && _transport.isConnected) {
        _sortForFlush();
        final entry = _queue.first;
        try {
          await _transport.send(entry.frame);
        } catch (_) {
          // Radio refused — keep the entry and retry on the next tick.
          return;
        }
        // The entry can only be removed by this loop (the lock is held), but
        // a concurrent clear() is still possible; guard the index anyway.
        if (_queue.isNotEmpty && identical(_queue.first, entry)) {
          _queue.removeAt(0);
        } else {
          _queue.remove(entry);
        }
        _persistToDisk();
      }
    } finally {
      _processing = false;
    }
  }

  void _tryFlush() {
    if (_processing || _queue.isEmpty) return;
    if (!_transport.isConnected) return;
    unawaited(flushNow());
  }

  /// The flush order, without mutating the queue.
  List<_QueuedFrame> _orderedForFlush() {
    final copy = List<_QueuedFrame>.of(_queue);
    copy.sort(_compareForFlush);
    return copy;
  }

  void _sortForFlush() => _queue.sort(_compareForFlush);

  /// Highest priority first; oldest first within a priority.
  static int _compareForFlush(_QueuedFrame a, _QueuedFrame b) {
    final byPriority = b.priority.compareTo(a.priority);
    if (byPriority != 0) return byPriority;
    return a.queuedAt.compareTo(b.queuedAt);
  }

  /// Drop entries past [maxAge], including after a long offline period.
  void _purgeExpired() {
    final cutoff = _now().subtract(maxAge);
    final before = _queue.length;
    _queue.removeWhere((e) => e.queuedAt.isBefore(cutoff));
    if (_queue.length != before) _persistToDisk();
  }

  /// Keep the newest, highest-priority entries when the cap is exceeded.
  void _trim() {
    while (_queue.length > maxEntries) {
      var victim = 0;
      for (var i = 1; i < _queue.length; i++) {
        final a = _queue[i];
        final b = _queue[victim];
        if (a.priority < b.priority ||
            (a.priority == b.priority && a.queuedAt.isBefore(b.queuedAt))) {
          victim = i;
        }
      }
      _queue.removeAt(victim);
    }
  }

  /// Clear all queued messages.
  void clear() {
    _queue.clear();
    _persistToDisk();
  }

  /// Remove a specific message by sequence ID (called on delivery receipt).
  bool removeBySequenceId(int seqId) {
    final before = _queue.length;
    _queue.removeWhere((e) => e.sequenceId == seqId);
    final removed = before - _queue.length;
    if (removed > 0) _persistToDisk();
    return removed > 0;
  }

  /// Stop the retry timer. The controller owns the queue, so it must call this
  /// on dispose or the timer outlives the screen and keeps the isolate awake.
  void dispose() {
    _timer?.cancel();
    _timer = null;
  }

  // ── Frame inspection ──────────────────────────────────────────

  /// Priority nibble from byte 3 of an iBFS frame (0 when unparseable).
  static int _priorityOf(Uint8List frame) {
    if (frame.length < 4) return 0;
    if (frame[0] != 0x49 || frame[1] != 0x54) return 0;
    return (frame[3] >> 4) & 0x0F;
  }

  /// Sequence ID from bytes 4-7 (0 when unparseable).
  static int _sequenceIdOf(Uint8List frame) {
    if (frame.length < 8) return 0;
    if (frame[0] != 0x49 || frame[1] != 0x54) return 0;
    return ByteData.sublistView(frame).getUint32(4, Endian.big);
  }

  // ── Persistence ────────────────────────────────────────────────

  Future<void> _persistToDisk() async {
    final prefs = await SharedPreferences.getInstance();
    final json = _queue.map((e) => e.toJson()).toList();
    await prefs.setString(_prefsKey, jsonEncode(json));
  }

  Future<void> _loadFromDisk() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsKey);
    if (raw == null) return;
    try {
      final list = jsonDecode(raw) as List;
      final loaded = <_QueuedFrame>[];
      for (final item in list) {
        final j = item as Map<String, dynamic>;
        final frameB64 = j['frame'] as String;
        final frame = base64Decode(frameB64);
        loaded.add(_QueuedFrame(
          frame: frame,
          sequenceId: j['seq'] as int,
          // Older builds did not persist the priority; recover it from the
          // frame header rather than defaulting every entry to routine.
          priority: (j['pri'] as int?) ?? _priorityOf(frame),
          queuedAt: DateTime.fromMillisecondsSinceEpoch(j['ts'] as int),
        ));
      }

      // The load is asynchronous and the caller may have enqueued (and even
      // flushed) frames while it was in flight. In that case the in-memory
      // queue is authoritative — appending the disk copy here used to send the
      // same message twice on startup.
      if (_queue.isEmpty) _queue.addAll(loaded);

      // A queue restored from a previous session may already be stale.
      _purgeExpired();
    } catch (_) {
      // Corrupted queue — start fresh.
    }
  }
}

class _QueuedFrame {
  final Uint8List frame;
  final int sequenceId;
  final int priority;
  final DateTime queuedAt;

  _QueuedFrame({
    required this.frame,
    required this.sequenceId,
    required this.priority,
    required this.queuedAt,
  });

  Map<String, dynamic> toJson() => {
        'frame': base64Encode(frame),
        'seq': sequenceId,
        'pri': priority,
        'ts': queuedAt.millisecondsSinceEpoch,
      };
}

class QueuedFrameInfo {
  final int sequenceId;
  final DateTime queuedAt;
  final int frameSize;

  /// Priority nibble decoded from the frame header.
  final int priority;

  QueuedFrameInfo({
    required this.sequenceId,
    required this.queuedAt,
    required this.frameSize,
    required this.priority,
  });

  /// Whether this entry is an emergency-priority frame.
  bool get isEmergency => priority == 0xF;

  // Internal factory — not exposed in public API signature.
  static QueuedFrameInfo _from(_QueuedFrame f) => QueuedFrameInfo(
        sequenceId: f.sequenceId,
        queuedAt: f.queuedAt,
        frameSize: f.frame.length,
        priority: f.priority,
      );
}
