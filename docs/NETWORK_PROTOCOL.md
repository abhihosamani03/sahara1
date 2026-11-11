# Network Protocol: Sahara Binary Framing Spec (iBFS-v1)

Raw JSON is prohibited on the wire — it wastes bytes on a channel where every byte matters. All messages use a fixed, byte-aligned binary header.

## 1. Corrected Packet Structure

The original draft used non-byte-aligned "0.5 byte" fields, which isn't a valid layout. Below, `Version`, `Type`, `Priority`, and `Lang` are packed two-per-byte using 4-bit nibbles — this is valid because each *pair* is byte-aligned, even though individual fields are 4 bits.

```
Byte 0-1:   Magic            (0x49 0x54, ASCII "IT")
Byte 2:     [Version:4][Type:4]      -- upper nibble = version, lower = packet type
Byte 3:     [Priority:4][Lang:4]     -- upper nibble = priority, lower = language ID
Byte 4-7:   Sequence ID              (uint32, big-endian)
Byte 8-9:   Payload Length N         (uint16, big-endian, 0 <= N <= 512)
Byte 10..(10+N-1):  Payload Data     (UTF-8 text or telemetry struct)
Byte (10+N)..(11+N): CRC-16-CCITT    (covers header + payload)
```

Total fixed overhead: 12 bytes header + 2 bytes CRC = 14 bytes, regardless of payload.

## 2. Field Specifications

| Field | Byte Offset | Size | Description |
|---|---|---|---|
| Magic | 0 | 2 | Fixed signature `0x49 0x54` |
| Version | 2 (high nibble) | 4 bits | `0x1` for v1.0 |
| Packet Type | 2 (low nibble) | 4 bits | `0x1` PTT voice, `0x2` Silent SOS, `0x3` Ack, `0x4` Store-and-forward (reserved), `0x5` Status/needs, `0x6` Check-in, `0x7` Early warning, `0x8` Assignment, `0x9` Voice-note chunk, `0xA` Relief ledger, `0xB` Missing person (see §2.2–2.4) |
| Priority | 3 (high nibble) | 4 bits | `0x0` Routine, `0x1` High, `0xF` Emergency |
| Language ID | 3 (low nibble) | 4 bits | See table below |
| Sequence ID | 4 | 4 bytes | Monotonic uint32, used for ack/retransmit and dedup in mesh mode |

### 2.1 Delivery receipts (`Packet Type 0x3`)

A receiver that decodes a valid frame sends one ACK back. Receipts are
machinery, not messages: they are never logged, spoken or alarmed.

- The ACK's **own** Sequence ID is fresh, because the mesh dedups on that
  field; reusing the confirmed frame's ID would make the receipt look like a
  duplicate and it would be dropped before the sender ever saw it.
- The **confirmed** Sequence ID travels as the payload text (decimal ASCII,
  e.g. `"49153"`). Payload overhead is 1 flag byte + the digits.
- The sender tracks unconfirmed frames, re-sends at 8 s intervals up to three
  attempts, and writes the frame off after 32 s. A receipt also removes any
  store-and-forward copy of the same sequence ID, so a replayed message is not
  sent again.
- Receipts are best-effort and are **not** themselves acknowledged (that would
  loop). A lost receipt therefore costs one duplicate transmission at most.
- No destination field exists, so a receipt proves *a* peer received the frame,
  not *which* peer — see APP_FEATURES.md §14.
| Payload Length | 8 | 2 bytes | N, in bytes |
| Payload Data | 10 | N bytes | UTF-8 text; optionally a structured sub-payload (see §4) |
| CRC-16 | 10+N | 2 bytes | CRC-16-CCITT over header+payload |

### 2.2 Mesh v2 envelope (`0x4D 0x53`, 9 bytes)

iBFS itself has no routing fields. The transport wraps each frame in a routing
header before it reaches a radio:

```
Byte 0-1:   Magic "MS" (0x4D 0x53)
Byte 2:     Envelope version (0x02)
Byte 3:     TTL (1..15, default 5)
Byte 4:     Hop count (incremented by every relay)
Byte 5-6:   Origin node ID (uint16, never 0 or 0xFFFF)
Byte 7-8:   Destination node ID (uint16, 0xFFFF = broadcast)
Byte 9..:   Unmodified iBFS frame (starts 0x49 0x54)
```

Relay rules (`MeshTransport`):

- Deduplicate on the **inner** iBFS Sequence ID, not the envelope bytes.
- Deliver when `destination == 0xFFFF` or `destination == this node`.
- Forward when `ttl > 1`, with `ttl - 1` and `hop + 1`, even for a frame
  addressed to another node.
- `BleMeshTransport.relayEnabled` is disabled in v2 mode so only one layer
  forwards frames.

A v1 receiver drops an enveloped frame (magic mismatch). Raw v1 frames are
still accepted, delivered and relayed, so a v2 node can hear a v1 node but not
the other way round. `sendTo()` and `lastHop` expose targeted sends and the hop
metric; delivery receipts in this build are still broadcast.

### 2.3 Structured reports (`0x5`–`0x8`)

The text field carries a compact JSON object instead of prose. A typical report
is 120–220 bytes, well under the 512-byte payload limit.

| Key | Meaning |
|---|---|
| `k` | kind: `sos`, `status`, `checkIn`, `warning`, `assignment` |
| `id` | incident ID (4 hex chars, stable across a beacon run) |
| `ts` | milliseconds since epoch |
| `from` | sender name (also in the payload header) |
| `lat`, `lon` | position (also in the payload header) |
| `sev` | 0 low, 1 moderate, 2 high, 3 critical |
| `vic`, `inj` | victims / injured counts |
| `need` | array of `water`, `food`, `medical`, `shelter`, `rescue` |
| `note` | sender's own text, in their language |
| `safe`, `ps`, `pm` | check-in result, people safe, people missing |
| `st` | `open`, `assigned`, `resolved` |
| `team`, `eta` | assigned responder and ETA in minutes |
| `r`, `exp` | warning radius in km, expiry timestamp |
| `bat` | sender battery percentage |

Receivers generate a short human summary locally (the JSON is never spoken).
A malformed body falls back to the raw text as a note rather than dropping the
frame. Position and sender identity from the iBFS header win over the JSON.

## 3. Language Code Table

The header's language field is a **4-bit nibble**, so it can only address 16 values, while Sahara supports the **22 languages of the Eighth Schedule plus English (23)**. The nibble therefore has a dual role:

- `0x0 – 0xE` — a language written **directly** into the nibble (15 slots).
- `0xF` — an **escape**: the nibble carries `0xF`, the `HasExtLang` flag is set, and the real language ID travels in a one-byte payload extension (§4).

The first ten IDs are **unchanged** from the original 10-language table, so an already-deployed build still interoperates byte-for-byte with this one. The escape is used only by languages added in the expansion.

### Direct IDs (0x0 – 0xE)

| Code | Language | Code | Language |
|---|---|---|---|
| 0x0 | Hindi (hi) | 0x8 | Bengali (bn) |
| 0x1 | Gujarati (gu) | 0x9 | English (en) |
| 0x2 | Marathi (mr) | 0xA | Punjabi (pa) |
| 0x3 | Kannada (kn) | 0xB | Urdu (ur) |
| 0x4 | Tamil (ta) | 0xC | Assamese (as) |
| 0x5 | Telugu (te) | 0xD | Nepali (ne) |
| 0x6 | Malayalam (ml) | 0xE | Konkani (kok) |
| 0x7 | Odia (or) | | |

### Escaped IDs (nibble `0xF` + extension byte)

| Ext | Language | Ext | Language |
|---|---|---|---|
| 0 | Maithili (mai) | 4 | Kashmiri (ks) |
| 1 | Sanskrit (sa) | 5 | Bodo (brx) |
| 2 | Sindhi (sd) | 6 | Manipuri (mni) |
| 3 | Dogri (doi) | 7 | Santali (sat) |

**Unknown IDs are not fatal.** If a receiver cannot resolve a language ID (a newer sender using a language this build does not know), it falls back to English rather than rejecting the frame — the CRC has already proven the bytes are intact, and on a distress channel a readable message beats a discarded one.

### Encoding a language inside the payload

The source-language and extended-language fields each carry the language's **full identity in one byte**:

- `0x00 – 0x0F` — the language's direct wire ID.
- `0x10 + extId` — an escaped language.

This one-byte form exists because the payload fields have room where the header nibble does not.

## 4. Extended Payload (Optional Sub-Fields for Differentiator Features)

Every payload **always** begins with a 1-byte flags field, followed by the extension fields that field advertises, in a fixed order:

```
Byte 0 of payload:   [HasGPS:1][HasSourceLang:1][HasSenderName:1][HasExtLang:1][Reserved:4]
                     bit 7    bit 6          bit 5          bit 4

If HasGPS          (bit 7):  lat (float32 BE) + lon (float32 BE)   8 bytes
If HasSourceLang   (bit 6):  sender's language, 1 byte (§3)         1 byte
If HasExtLang      (bit 4):  extended language ID, 1 byte (§3)       1 byte
If HasSenderName   (bit 5):  name length, 1 byte + UTF-8 name      1 + N bytes
Remaining bytes:             UTF-8 message text
```

The order is **fixed and normative**, not a convention: the decoder walks the
payload left to right, consuming exactly the bytes each set flag implies. Only
the presence of a field is optional, never its position.

This keeps the common case (plain text, no extras) at exactly **one byte** of overhead, while supporting GPS-stamped distress messages, cross-language relay, the 23-language space and sender identity without a second protocol.

### Sender name (`HasSenderName`, bit 5)

Who is speaking, so another operator knows whose voice they are hearing.

- **Max 8 characters**, enforced by the Settings screen and clamped again by the encoder. Eight Devanagari characters are 24 bytes, so the length prefix counts **bytes** while the limit counts **characters**; the encoder therefore also caps the name at 64 bytes to guarantee it can never crowd the message out of a 512-byte payload.
- The name is a **structured field, not a `"[Name]: message"` text prefix**. A prefix would be fed to the translation model (producing a mangled name in the spoken translation) and would consume bytes on every single message; the structured form costs nothing when no name is set, and lets the receiver render it separately and speak only the message.
- An empty or whitespace-only name is encoded as *absent* — no length byte, no flag.

## 5. Reliability
- **CRC-16 validation**: corrupted frames are silently dropped, not retransmitted automatically at this layer (retransmission is handled at the app layer via ack timeout, not baked into every packet, to keep overhead minimal on distress/emergency packets which favor speed over guaranteed delivery).
- **Ack packets** (`Type = 0x3`) are optional per message — the sender should not block the UI waiting for one; use them for reliability logging/retry, not for gating whether the PTT button re-enables.
- **Sequence ID** doubles as a dedup key in mesh/store-and-forward mode (see ADDITIONAL_FEATURES.md) — a relay node drops any packet whose sequence ID it has already forwarded.

## 6. Frame Size Reference

| Payload | Approx. size |
|---|---|
| Raw WAV audio, 3s @ 16kHz/16-bit | ~96,000 bytes |
| Opus-compressed audio, 12kbps | ~4,500 bytes |
| Sahara text packet, typical sentence | ~40-80 bytes total (incl. 14-byte overhead) |
| Sahara text packet + GPS + source-lang flag | ~55-95 bytes |

The original draft's claim of "38 bytes in <5ms" for transfer over RFCOMM is plausible for the raw radio hop alone — but don't present that figure as your *total* system latency; it excludes STT inference, TTS inference, and connection handshake time. State it explicitly as "network transfer only" wherever you cite it, to avoid a judge catching the discrepancy against your end-to-end latency claim.

## 7. Transport Implementation (as built)

Two radios run at once and both carry the same iBFS frames. Neither requires a hotspot,
a router, an internet connection, or user-visible pairing.

### 7.1 BLE GATT mesh (`lib/net/ble_transport.dart`)

Every device runs **both** GATT roles simultaneously, so there is no host/client split
and PTT works symmetrically in both directions:

- **Peripheral role** — advertises the Sahara service UUID and serves the frame
  characteristic.
- **Central role** — scans (rotating the scan session every 15 s, because Android
  silently stops delivering results), connects to nodes advertising the service, and
  subscribes to notifications.
- **Flooding relay** — a received frame is relayed once to every other peer, deduped by
  Sequence ID, so a 2+ node cluster extends range without a routing table.
- **Reconnect retries** — peers seen in an advertisement are remembered and re-connected
  with backoff, instead of waiting for Android to re-report a cached scan result.

### 7.2 BLE link-layer fragmentation (fixes CRC mismatch corruption)

An iBFS frame is up to 524 bytes; one ATT write/notify carries 20–512 bytes depending on
negotiated MTU. A frame therefore travels as several chunks:

```
Byte 0:     0xB5                     chunk magic (never 0x49 'I', so it cannot be
                                     confused with a complete iBFS frame)
Byte 1-2:   Fragment ID (uint16 BE)   one per outbound frame
Byte 3:     Chunk index (0-based)
Byte 4:     Chunk count
Byte 5..:   Chunk data
```

Receive order matters and is now enforced: **reassemble → validate magic → dedup by
Sequence ID → deliver once → relay**. Feeding individual ATT chunks straight to
`decodeIbfs()` was previously producing `CRC mismatch: expected 0x3680, computed 0x4e98`
for every frame larger than one ATT payload. Chunk sizes come from
`getMaximumWriteLength()` / `getMaximumNotifyLength()`, so notifications are never
silently truncated by the OS stack.

### 7.3 Wi-Fi Direct (`android/app/src/main/kotlin/com/example/voice/WifiDirectPlugin.kt`)

Adds range and bandwidth as a second, independent radio:

- Both devices call `discoverPeers()`; group formation is left to Wi-Fi Direct's own
  owner negotiation, biased deterministically by device address when the OS exposes it.
- The group owner opens a TCP server on port 8988; clients connect to the owner's P2P
  address. Frames are length-prefixed (`int32` big-endian + payload) and relayed by the
  owner to all other members.
- An owner whose group nobody joins gives the group up after 25 s, so two phones can
  never get stuck in two separate one-member groups.

### 7.4 Aggregation and dedup (`lib/net/mesh_transport.dart`)

The two radios are aggregated behind one `Transport`. Frames are sent on every live
radio, and inbound traffic is deduplicated on `(Sequence ID)` *across* radios, so a
packet that arrives over both BLE and Wi-Fi Direct is decoded and spoken exactly once.

Bluetooth starts first; Wi-Fi Direct joins after 12 s if Bluetooth is still up but
peerless (this is precisely the case where an active Wi-Fi link is starving BLE
discovery), or immediately if Bluetooth could not start at all. If no peer is reachable,
`send()` fails and the frame is queued for store-and-forward instead of being dropped
silently.

Half-duplex discipline: while a device is recording, processing or transmitting, an
inbound frame is logged but not spoken, so the receiver's speaker cannot be picked up by
its own microphone and re-transmitted.
