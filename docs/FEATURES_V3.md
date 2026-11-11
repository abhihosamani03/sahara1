# Sahara 0.4.0 — field coordination, offline content and homing

Seven features were added on top of 0.3.0. All of them work without a server;
anything that needs the internet is explicitly user-triggered and caches its
result for offline use.

## 1. Targeted delivery receipts

Every valid inbound frame is acknowledged, and the envelope's `origin` field is
used as the receipt's destination (`MeshTransport.sendTo`). A receipt therefore
stops after N hops instead of flooding the mesh, and a sender knows *who*
received the frame. When the frame arrived as a legacy raw iBFS frame there is
no origin to address, so the receipt falls back to broadcast.

## 2. Relay store-and-forward

`StoreForwardQueue` only ever held this phone's own messages. `RelayQueue`
(new, `lib/net/relay_queue.dart`) now keeps frames heard **for other nodes**
when no second radio is available, keyed by the inner iBFS sequence ID, capped
at 40 entries and 2 hours, and flushes them as soon as a peer appears
(`MeshTransport._flushRelayQueue`). TTL still bounds how far they travel.

## 3. Voice-note fallback

When transcription fails (noise, accent, unsupported language) a short clip can
be sent instead: AAC at 16 kbit/s is split into 280-byte chunks, each carried
as a `voiceChunk` (0x9) JSON frame of ~410 bytes, reassembled by
`VoiceNoteAssembler`, written to the cache and played with `audioplayers`.
Half-duplex discipline is respected: a note is not played while this phone is
transmitting. Limits: ~15 s per note (`VoiceNoteChunk.maxNoteBytes`), no
encryption, and chunks are not individually receipted — the log reports how
many frames left the radio.

## 4. OpenStreetMap tiles, cached offline

`lib/net/osm_tiles.dart` downloads the 3×3 tile block around a position into
`<documents>/offline_tiles/<z>/<x>/<y>.png` — the layout `OfflineMapView`
already reads. The map screen has a download button for exactly this. The
downloader follows the OSM tile policy: descriptive User-Agent, sequential
requests at ≥ 1.1 s, a hard cap of 9 tiles per run, and existing tiles are
never re-fetched. It is not a bulk scraper.

## 5. Early-warning ingestion (RSS/Atom)

`lib/state/alert_feed.dart` parses RSS 2.0 and Atom (title, description/summary,
date, link), strips HTML, decodes entities and deduplicates. Feed URLs are
stored in Settings (`set.alertFeeds`). "Fetch alerts" runs only when tapped;
each alert can then be rebroadcast as a normal `alert` (0x7) packet, which
alarms and speaks on every receiver with no internet of theirs. Nothing is
polled in the background, and one broken feed does not hide the others.

## 6. Relief camp ledger

`ReliefLedger` stores camps with per-resource needs and supplies
(water/food/medical/shelter/rescue), merges updates last-writer-wins by
timestamp with a reporter-name tie-break, persists to
`SharedPreferences`, and totals shortfalls across camps. Camp state is
gossiped as a `reliefUpdate` (0xA) JSON packet; a camp post can therefore
publish "200 water needed, 40 on hand" in one frame and every responder's
ledger converges.

## 7. RSSI homing + missing-person registry

BLE advertisements carry an RSSI; `BleMeshTransport.peerRssi` exposes it and
the homing screen ranks peers by signal with an explicit warning that RSSI is a
distance hint, not a bearing. `MissingRegistry` stores name, age, last-seen and
note, merges by recency and gossips records as a `missingPerson` (0xB) packet.

**Photo limit:** thumbnails stay on the reporting phone. A thumbnail would cost
roughly 20 mesh frames and crowd out live SOS traffic, so records relayed to
other phones explicitly say the photo is on the reporter's device instead of
pretending the image arrived. Attaching a photo currently requires a local file
path (no gallery picker is bundled).

## Verification

```
flutter analyze  → No issues found
flutter test     → 140/140 passing
```

New tests: `relay_queue_test`, `osm_tiles_test`, `alert_feed_test`,
`relief_ledger_test`, `voice_note_test`, `missing_registry_test`.

## Not included

Encryption / SOS signing, a Codec2 codec, targeted receipts for frames that
arrived without an envelope, photo transfer over the mesh, and a two-phone
field test.
