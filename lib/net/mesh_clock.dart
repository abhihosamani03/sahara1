import 'dart:math' as math;

/// Wall-clock alignment across a mesh with no internet.
///
/// Phones in a disaster area can be minutes apart, which makes log ordering,
/// relay expiry and last-writer-wins ledger merges disagree. A `timeSync`
/// packet carries the sender's epoch milliseconds; this class keeps a bounded,
/// median-filtered offset from that sample.
///
/// The offset is one-way (`remote - local`), so radio latency biases it by the
/// one-way delay (tens of milliseconds on BLE, single digits on Wi-Fi Direct).
/// That is far below the minutes this exists to correct, and the class says so
/// rather than pretending to be NTP.
class MeshClock {
  MeshClock({this.maxSamples = 9, DateTime Function()? localNow})
      : _localNow = localNow ?? DateTime.now;

  final int maxSamples;
  final DateTime Function() _localNow;
  final List<int> _samples = <int>[];

  int _offsetMs = 0;

  /// Current estimated offset: add to local time to get mesh time.
  int get offsetMs => _offsetMs;

  /// Number of accepted samples.
  int get sampleCount => _samples.length;

  /// Whether at least one peer sample has been seen.
  bool get synced => _samples.isNotEmpty;

  /// Local clock adjusted to mesh time.
  DateTime now() => _localNow().add(Duration(milliseconds: _offsetMs));

  /// Feed a peer's `epochMs`, observed at [receivedAt] (defaults to now).
  ///
  /// The median is used instead of the mean so one phone with a badly wrong
  /// clock cannot drag the whole mesh with it.
  void observe(int epochMs, {DateTime? receivedAt}) {
    if (epochMs <= 0) return;
    final local = (receivedAt ?? _localNow()).millisecondsSinceEpoch;
    final delta = epochMs - local;
    // Ignore absurd samples (badly corrupted or a phone set to 1970).
    if (delta.abs() > const Duration(days: 7).inMilliseconds) return;
    _samples.add(delta);
    if (_samples.length > maxSamples) _samples.removeAt(0);
    final sorted = List<int>.of(_samples)..sort();
    _offsetMs = sorted[sorted.length ~/ 2];
  }

  /// Reset to local time.
  void reset() {
    _samples.clear();
    _offsetMs = 0;
  }

  /// Human-readable offset, e.g. `+2.4 s` or `−180 ms`.
  String get label {
    if (!synced) return 'local clock';
    final ms = _offsetMs;
    final abs = ms.abs();
    final sign = ms < 0 ? '−' : '+';
    if (abs >= 1000) {
      final seconds = abs / 1000.0;
      return '$sign${seconds.toStringAsFixed(seconds >= 10 ? 0 : 1)} s';
    }
    return '$sign$abs ms';
  }

  /// Median of the raw samples, exposed for diagnostics/tests.
  int get medianSample {
    if (_samples.isEmpty) return 0;
    final sorted = List<int>.of(_samples)..sort();
    return sorted[sorted.length ~/ 2];
  }

  /// Largest sample deviation, used to surface a disagreeing peer.
  int get spreadMs {
    if (_samples.isEmpty) return 0;
    var low = _samples.first, high = _samples.first;
    for (final s in _samples) {
      low = math.min(low, s);
      high = math.max(high, s);
    }
    return high - low;
  }
}
