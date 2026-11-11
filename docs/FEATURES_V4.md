# Sahara 0.5.0 — routed mesh, field clock, incident map and breadcrumbs

This build extends the 0.4.0 field-coordination layer. Everything below is
implemented in this repository and covered by `flutter analyze` and
`flutter test`; the two-phone radio behaviour still needs a field test.

## 1. Mesh v3: next-hop routing and path trace

The 9-byte v2 envelope is replaced by a 12-byte v3 header plus a relay path:

```text
0-1   "MS"
2     version 3
3     TTL (1..15)
4     hop count
5-6   origin node ID
7-8   destination (0xFFFF = broadcast)
9-10  next hop (0 = flood)
11    path length (0..8)
12..  path: relay node IDs, 2 bytes each
..    unmodified iBFS frame
```

`MeshTransport` learns a route to each origin from the relay that delivered its
frame (`path.last`) and stores it for two minutes, preferring the shorter hop
count. A targeted frame then carries that next hop, and only that neighbour
relays it; with no route yet the frame floods as before. The path grows by one
node per relay and is capped at eight, so the trace is bounded.

v2 frames are still decoded and delivered. Both phones must run a build that
understands v3 for the routing fields to be used, but a v3 frame does not break
a v2 receiver's frame decoder — it is dropped at the envelope layer.

## 2. Mesh time sync

A `timeSync` packet (type `0xC`) carries the sender's epoch milliseconds. The
receiver keeps the **median** of its last nine samples (`MeshClock`), so one
phone with a badly wrong clock cannot drag the mesh. The offset is exposed in
Settings and applied to log timestamps once synced. Samples older than a week
or obviously corrupt are ignored. A sample is broadcast on the first peer
appearance and every five minutes.

This is one-way offset estimation, not NTP: radio latency biases it by the
one-way delay (tens of milliseconds), which is far below the minutes it exists
to correct. The class says so rather than overclaiming.

## 3. Congestion priority preemption

An emergency frame (priority nibble `0xF`) opens a four-second quiet window.
Bulk traffic — relief-ledger gossip, missing-person records, breadcrumb
batches and clock samples — waits for that window through `sendBulk()`, bounded
at six seconds so a stuck flag cannot block a camp update forever. Interactive
messages and SOS frames use `send()` and are never delayed.

## 4. Relay-only mode

Settings → Field network → *Relay-only mode* turns the phone into a repeater:
BLE advertising and scanning stay up with a 30-second scan rotation and a
20-second reconnect cadence, Wi-Fi Direct is switched off, the microphone and
speaker are disabled (`canTransmit`/`canReceive` are false), and the home screen
shows a persistent `RELAY ONLY` banner. The radio is not restarted on toggle;
the policy applies to the next mesh start and immediately to scanning.

## 5. Start on boot

`BootReceiver` listens for `BOOT_COMPLETED` and `MY_PACKAGE_REPLACED` and, only
when *Start on boot* is enabled, creates the cached Flutter engine
(`SaharaEngine`) and starts `SosService`. The service also ensures the engine
itself, so the mesh can come up with no Activity attached. The preference is
read with Flutter's `flutter.` shared-preferences prefix.

## 6. Incident overlay on the offline map

`IncidentMapScreen` plots every positioned incident (SOS, needs, check-in,
warning) on the existing offline tile renderer, colour-coded and labelled, with
an SOS pin style. `OfflineMapView` now accepts a marker list and trail
polylines instead of a single position; the original single-position map and
its graticule fallback are unchanged. Entry points: coordination menu →
*Incident map*, and Settings → Field network.

## 7. MBTiles region bundles

Settings → Field network → *Import offline map region (.mbtiles)* uses the
system file picker, opens the archive read-only with SQLite, and writes tiles
into `<documents>/offline_tiles/<z>/<x>/<y>.png`, flipping the TMS row to XYZ.
It reads in pages of 400 rows, skips tiles already present, accepts zooms 2–18,
and caps one import at 20,000 tiles. A `.mbtiles` district pack is therefore a
one-tap offline region; existing tiles are never overwritten.

## 8. Responder breadcrumb trail

With *Share breadcrumb trail* enabled, a low-accuracy GPS fix is taken every
30 seconds, kept only when the phone moved at least ~8 m or 20 seconds passed,
and the last 20 points are gossiped as a `breadcrumb` packet (type `0xD`).
Receivers merge by timestamp into a per-sender trail, deduplicate, and draw the
polylines on the incident map. The local trail is capped at 240 points; the
wire batch stays far below the 512-byte payload ceiling.

## Not in this build

These were requested for this release and are **not** implemented, so the app
does not pretend to have them:

- **BLE Coded PHY (long range).** The `bluetooth_low_energy` 6.x plugin exposes
  no PHY selection, and its advertiser/GATT objects are private. Setting the
  coded PHY requires replacing the BLE transport with a native
  advertiser/scanner/GATT stack — a separate, testable piece of work, not a
  flag.
- **Wi-Fi Aware (NAN).** No maintained Flutter package exists; the only pub
  candidate is a 2021 template with no API. A native publish/subscribe plus
  socket plugin is required. Shipping an untested native radio alongside BLE,
  Wi-Fi Direct and the new relay policy would risk the existing links.
- **Codec2 real-time voice.** A real Codec2 integration needs the LGPL codec
  compiled through the NDK, an FFI/JNI bridge, 8 kHz capture, and a streaming
  `AudioTrack` playback path with a jitter buffer. The existing voice note
  (AAC, ~15 s, chunked) remains the fallback. No half-implementation is
  claimed as Codec2.

## Verification

```text
flutter analyze  → No issues found
flutter test     → 148/148 passing
```

Unit coverage added for envelope v3 path/next-hop, mesh clock median/labels,
and breadcrumb merge/encode/gating. Radio routing, boot start, MBTiles import
and breadcrumb capture are compile-verified and need two-phone field testing.
