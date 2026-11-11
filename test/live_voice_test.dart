import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:itantra/ml/ibfs.dart';
import 'package:itantra/ml/languages.dart';
import 'package:itantra/net/mesh_transport.dart';

void main() {
  test('a live-voice burst survives the iBFS round trip', () {
    final data =
        Uint8List.fromList(List<int>.generate(24, (i) => (i * 7) & 0xFF));
    final text = jsonEncode({'d': base64Encode(data)});

    final frame = encodeIbfs(IbfPacket(
      type: PacketType.voiceFrame,
      priority: Priority.high,
      language: kHindi,
      sequenceId: 42,
      text: text,
    ));
    final decoded = decodeIbfs(frame);

    expect(decoded.type, PacketType.voiceFrame);
    expect(decoded.text, text);
    final parsed = jsonDecode(decoded.text) as Map<String, dynamic>;
    expect(base64Decode(parsed['d'] as String), data);
  });

  test('radio detail names the long-range and Wi-Fi Aware links', () {
    const stats = LinkStats(
      bleRunning: true,
      bleScanning: true,
      blePeers: 1,
      bleKnownPeers: 2,
      bleStatus: 'linked',
      wifiDirectRunning: false,
      wifiDirectSupported: true,
      wifiDirectPeers: 0,
      wifiDirectStatus: 'off',
      codedPhyRunning: true,
      codedPhySupported: true,
      codedPhyPeers: 1,
      codedPhyStatus: 'coded',
      codedPhyActive: true,
      wifiAwareRunning: true,
      wifiAwareSupported: true,
      wifiAwarePeers: 1,
      wifiAwareStatus: 'listening',
    );

    expect(stats.detail, contains('Coded PHY'));
    expect(stats.detail, contains('Wi-Fi Aware'));
    expect(stats.totalPeers, 3);
    expect(stats.anyRunning, isTrue);
  });
}
