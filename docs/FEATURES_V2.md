# Sahara 0.3.0 — Coordination, Mesh v2 and Early Warning

This build adds the second layer on top of the Phase-1 transceiver: the mesh can
now route with a hop limit, messages carry delivery semantics, and the app
collects structured incident reports instead of only free text.

Everything below is implemented in this repository and covered by
`flutter test`. Nothing in this document is aspirational unless it appears under
**Limits**.

---

## 1. Mesh v2 envelope (transport layer)

iBFS frames are deliberately minimal: 10-byte header, payload, CRC. They have no
hop limit, no sender identity and no destination, so a relayed frame could
circulate until every radio happened to drop it, and every phone had to process
every frame.

`lib/net/mesh_envelope.dart` wraps an **unmodified** iBFS frame in a 9-byte
routing header:

```text
Byte 0-1   Magic "MS" (0x4D 0x53)
Byte 2     Envelope version (0x02)
Byte 3     TTL (1..15)
Byte 4     Hop count
Byte 5-6   Origin node ID (uint16, never 0 / 0xFFFF)
Byte 7-8   Destination node ID (uint16, 0xFFFF = broadcast)
Byte 9..   iBFS frame, byte-for-byte
```

Behaviour in `MeshTransport`:

- Outbound frames are enveloped with `ttl = 5` and the local random 16-bit node
  ID as origin.
- Inbound envelopes are deduplicated on the **inner** iBFS sequence ID, so the
  same message arriving over BLE, Wi-Fi Direct and two relays is still delivered
  once.
- A frame is delivered locally when the destination is broadcast or this node.
- A frame is forwarded (TTL − 1, hop + 1) while `ttl > 1`, regardless of whether
  it was addressed to this node, so a targeted message can still use this phone
  as a stepping stone.
- `BleMeshTransport.relayEnabled` is turned **off** by `MeshTransport`: routing
  lives in exactly one layer, and BLE's own relay would otherwise forward every
  hop twice.

`MeshTransport.sendTo(frame, destination)` exists for targeted frames, and
`lastHop` / `relayedFrames` expose the routing metric for the UI.

**Compatibility:** a v1 build treats an enveloped frame as garbage (magic
mismatch) and drops it. Raw v1 frames are still accepted, delivered and
relayed. Both phones in a demo must run the same build.

## 2. New packet types

| Value | Type | Payload |
|---|---|---|
| `0x1` | PTT voice | UTF-8 transcript |
| `0x2` | Silent SOS | SOS text + medical block |
| `0x3` | ACK | decimal sequence ID being confirmed |
| `0x4` | Store-and-forward (reserved) | — |
| `0x5` | **Status / needs** | JSON triage record |
| `0x6` | **Check-in** | JSON safe / not-safe + head count |
| `0x7` | **Early warning** | JSON severity, radius, expiry, text |
| `0x8` | **Assignment** | JSON team + ETA for an incident |

Structured payloads use the existing text field, so there is no wire-format
change: a full report is typically 120–220 bytes, well under the 512-byte
payload cap. The JSON is never spoken — each type has a generated human summary
(`IncidentReport.summaryLine`) used for the log, TTS and the alarm banner.

Compact keys: `k` kind, `id` incident, `ts`, `from`, `lat`, `lon`, `sev`
(0–3), `vic`, `inj`, `need` (water/food/medical/shelter/rescue), `note`, `safe`,
`ps`/`pm` (people safe/missing), `st` status, `team`, `eta`, `r` radius km,
`exp` expiry, `bat` battery %.

A malformed body is not dropped: the frame's CRC already proved it arrived
intact, so the raw text is treated as a note.

## 3. Incident board (offline coordination)

`lib/state/incident.dart` + `lib/ui/incident_board_screen.dart`.

One SOS incident ID = one row. The board aggregates:

- active SOS calls,
- sites with needs (water / food / medical / shelter / rescue),
- safe and missing head counts from check-ins,
- injured counts from status reports,
- early warnings.

It sorts by severity then recency, persists to `SharedPreferences`, caps itself
at 200 reports, ignores replayed older copies (so an incident cannot roll back
from "assigned" to "open"), and supports **assign** (team + ETA) and
**resolve**. An assignment updates the incident it names instead of creating a
second row.

Open it from the app bar → coordination menu → *Incident board*.

## 4. SOS beacon

`TransceiverController.startSosBeacon()` sends a distress frame immediately and
then repeats it every **45 s** (90 s when the battery is low or the device is
thermally critical), up to **12** pings.

- Each ping carries a fresh GPS fix, the ping number, battery % and the medical
  block.
- The run stops as soon as a delivery receipt matches one of its frames.
- A failed ping is queued for store-and-forward instead of being lost.

## 5. Real battery + thermal channel

`BatteryMonitor` now calls the `itantra/device` MethodChannel
(`SaharaChannels.registerDevice`), which returns:

- `level` from `BatteryManager.BATTERY_PROPERTY_CAPACITY`,
- `charging` from `BatteryManager.isCharging` (API 23+),
- `thermal` from `PowerManager.currentThermalStatus` (API 29+), mapped to
  nominal / light / moderate / severe / critical / emergency / shutdown.

If the channel is unavailable (tests, desktop, an OEM that hides capacity) the
last known values are kept rather than invented — a fabricated 100 % would
silently disable every low-battery safeguard. The beacon and the SOS text use
the real reading.

## 6. UI

The app bar gained one coordination menu:

- Incident board (with a badge for active SOS calls)
- "I'm safe" check-in
- Report needs / triage
- Send early warning
- Start / stop the SOS beacon

The warning dialog broadcasts text that every receiver **speaks and alarms**,
with no internet at either end.

## 7. Verification

```text
flutter analyze   → No issues found
flutter test      → 107/107 passing (20 new tests)
flutter build apk --release --split-per-abi → exit 0
```

New tests cover: envelope round-trip, TTL/hop forwarding, malformed headers,
reserved IDs, all four new packet types, incident JSON round-trip, header
position winning over body position, legacy plain-text SOS, board aggregation,
assignment merging, replay protection, resolve, and persisted-board loading.

Release artifact: `release-v2/app-arm64-v8a-release.apk`
(63,985,892 bytes, SHA-256
`fb6243e4d7a08aaff756f8b14f2968837938aeab6ac3c96a5298f08b75c96a9b`,
versionName 0.3.0, arm64 versionCode 5000, debug certificate).

## Limits (deliberately not claimed)

- **No encryption or SOS signing.** A shared-key HMAC is the next step; today a
  forged village-wide alarm is still possible.
- **Receipts are broadcast, not targeted.** The envelope supports a destination
  and `sendTo()` exists, but a receipt does not yet prove *which* peer heard it.
- **No compressed voice fallback.** If STT fails, text still has to be typed.
- **No map tile bundle.** The offline map draws a graticule unless tiles are
  installed in `Documents/offline_tiles`.
- **No field test.** Routing, beacon timing and battery throttling are verified
  by unit tests and compilation only, not on two physical phones.
- **v1 ⇄ v2 coexistence is partial** (see §1).
