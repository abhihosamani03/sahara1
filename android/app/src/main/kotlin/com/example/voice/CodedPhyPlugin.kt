package com.example.voice

import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattDescriptor
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.bluetooth.le.AdvertisingSet
import android.bluetooth.le.AdvertisingSetCallback
import android.bluetooth.le.AdvertisingSetParameters
import android.bluetooth.le.BluetoothLeAdvertiser
import android.bluetooth.le.BluetoothLeScanner
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.ParcelUuid
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.ArrayDeque
import java.util.UUID

/**
 * Bluetooth LE **Coded PHY** (long range) link for Sahara.
 *
 * The `bluetooth_low_energy` plugin used by `BleMeshTransport` exposes no PHY
 * control, so ordinary Sahara links run on the 1M PHY. That costs roughly 4×
 * range compared with Coded PHY (S=8), which is exactly the difference between
 * "the next street" and "the next block" after a disaster. This class adds a
 * second, independent BLE path that runs entirely on native APIs:
 *
 *  - **Advertising:** an extended (non-legacy) advertising set whose primary
 *    and secondary PHY are both `PHY_LE_CODED`. The legacy advertiser cannot
 *    transmit on Coded, so a Coded scan never sees the plugin's 1M
 *    advertisement — this set is what makes the node discoverable at range.
 *  - **Scanning:** an unfiltered scan restricted to the Coded PHY (hardware
 *    128-bit UUID filters are unreliable, so filtering happens in software,
 *    exactly as `BleMeshTransport` does).
 *  - **Data:** a native GATT client. It connects to the peer's Sahara GATT
 *    server (published by the plugin), asks the controller for the Coded PHY
 *    with `setPreferredPhy`, negotiates MTU, and then exchanges frames.
 *
 * Frames are chunked with the same 5-byte envelope as `fragmentation.dart`
 * (`0xB5`, fragment id, index, count) so the peer's existing reassembler can
 * read them, and inbound chunks are reassembled here before reaching Dart.
 *
 * Everything degrades to "unsupported" on devices without Coded PHY support;
 * the caller then simply keeps the 1M link.
 */
class CodedPhyPlugin(
    private val context: Context,
    messenger: BinaryMessenger,
) : MethodChannel.MethodCallHandler, EventChannel.StreamHandler {

    private companion object {
        const val METHOD_CHANNEL = "itantra/ble_coded_phy"
        const val EVENT_CHANNEL = "itantra/ble_coded_phy/events"

        /** Must match `BleMeshTransport.serviceUuid`. */
        val SERVICE_UUID: UUID = UUID.fromString("8f1d3a50-6f2c-4c1e-9b7a-5a2e9d0c1a10")

        /** Must match `BleMeshTransport.frameCharUuid`. */
        val FRAME_UUID: UUID = UUID.fromString("8f1d3a50-6f2c-4c1e-9b7a-5a2e9d0c1a11")

        /** Client Characteristic Configuration descriptor. */
        val CCCD_UUID: UUID = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")

        /** Must match `FrameFragmenter.magic` / `headerLen` in Dart. */
        const val CHUNK_MAGIC = 0xB5
        const val CHUNK_HEADER = 5

        /** BLE 4.0 default ATT payload (MTU 23). */
        const val MIN_PAYLOAD = 20

        /** Long-range links are scarce: do not hold more than a few. */
        const val MAX_LINKS = 2

        /** Give up on a peer that stops responding for this long. */
        const val RECONNECT_MS = 15_000L

        /** A partially reassembled frame is dropped after this long. */
        const val ASSEMBLY_TTL_MS = 8_000L
    }

    private val handler = Handler(Looper.getMainLooper())
    private val methodChannel = MethodChannel(messenger, METHOD_CHANNEL)
    private val eventChannel = EventChannel(messenger, EVENT_CHANNEL)

    private var eventSink: EventChannel.EventSink? = null
    private var adapter: BluetoothAdapter? = null
    private var advertiser: BluetoothLeAdvertiser? = null
    private var scanner: BluetoothLeScanner? = null
    private var advertisingSet: AdvertisingSet? = null

    private var running = false
    private var scanning = false
    private var codedNegotiated = false
    private var lastConnectAttempt: Long = 0

    /** Native GATT client links, keyed by device address. */
    private val links = LinkedHashMap<String, Link>()

    /** Partially reassembled inbound frames, keyed by "address/fragmentId". */
    private val assemblies = HashMap<String, Assembly>()

    private var nextFragmentId = 0

    private data class Link(
        val device: BluetoothDevice,
        var gatt: BluetoothGatt? = null,
        var frameCharacteristic: BluetoothGattCharacteristic? = null,
        var payload: Int = MIN_PAYLOAD,
        var writeQueue: ArrayDeque<ByteArray> = ArrayDeque(),
        var writing: Boolean = false,
        var ready: Boolean = false,
        var coded: Boolean = false,
    )

    private class Assembly(val count: Int) {
        val parts = arrayOfNulls<ByteArray>(count)
        var received = 0
        val createdAt = System.currentTimeMillis()
    }

    init {
        methodChannel.setMethodCallHandler(this)
        eventChannel.setStreamHandler(this)
    }

    // ── Method channel ───────────────────────────────────────────────

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "capabilities" -> result.success(capabilities())

            "start" -> result.success(start())

            "stop" -> {
                stop()
                result.success(true)
            }

            "send" -> {
                val data = call.argument<ByteArray>("data")
                if (data == null || data.isEmpty()) {
                    result.error("ARG", "Missing frame payload", null)
                    return
                }
                result.success(send(data))
            }

            "status" -> result.success(statusMap())

            else -> result.notImplemented()
        }
    }

    private fun capabilities(): Map<String, Any?> {
        val a = bluetoothAdapter()
        val supported = a != null &&
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            a.isLeCodedPhySupported
        return mapOf(
            "supported" to supported,
            "extendedAdvertising" to (
                supported &&
                    Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
                    (a?.isLeExtendedAdvertisingSupported == true)
                ),
            "status" to if (supported) currentStatus() else "unsupported",
        )
    }

    // ── Event channel ────────────────────────────────────────────────

    override fun onListen(arguments: Any?, sink: EventChannel.EventSink?) {
        eventSink = sink
        emitStatus(currentStatus())
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
    }

    // ── Lifecycle ────────────────────────────────────────────────────

    private fun start(): Boolean {
        if (running) return true

        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            emitStatus("unsupported")
            emitError("LE Coded PHY needs Android 8.0 or newer")
            return false
        }
        val a = bluetoothAdapter()
        if (a == null) {
            emitStatus("unsupported")
            return false
        }
        if (!a.isEnabled) {
            emitStatus("bluetooth-off")
            emitError("Bluetooth is switched off")
            return false
        }
        if (!a.isLeCodedPhySupported) {
            emitStatus("unsupported")
            emitError("This phone's Bluetooth radio has no LE Coded PHY")
            return false
        }
        if (!granted(android.Manifest.permission.BLUETOOTH_SCAN) &&
            !granted(android.Manifest.permission.ACCESS_FINE_LOCATION)
        ) {
            emitStatus("permission-denied")
            emitError("Bluetooth scan permission is required for long range")
            return false
        }

        adapter = a
        advertiser = a.bluetoothLeAdvertiser
        scanner = a.bluetoothLeScanner

        if (advertiser == null || scanner == null) {
            emitStatus("unsupported")
            emitError("Bluetooth LE advertising/scanner unavailable")
            return false
        }

        running = true
        startAdvertising()
        startScanning()
        emitStatus(currentStatus())
        return true
    }

    private fun startAdvertising() {
        val adv = advertiser ?: return
        try {
            val params = AdvertisingSetParameters.Builder()
                .setLegacyMode(false)
                .setConnectable(true)
                .setPrimaryPhy(BluetoothDevice.PHY_LE_CODED)
                .setSecondaryPhy(BluetoothDevice.PHY_LE_CODED)
                .setInterval(AdvertisingSetParameters.INTERVAL_MEDIUM)
                .setTxPowerLevel(AdvertisingSetParameters.TX_POWER_MEDIUM)
                .build()

            val data = android.bluetooth.le.AdvertiseData.Builder()
                .addServiceUuid(ParcelUuid(SERVICE_UUID))
                .setIncludeDeviceName(true)
                .build()

            adv.startAdvertisingSet(
                params,
                data,
                null,
                null,
                null,
                object : AdvertisingSetCallback() {
                    override fun onAdvertisingSetStarted(
                        set: AdvertisingSet?,
                        txPower: Int,
                        status: Int,
                    ) {
                        advertisingSet = set
                        if (status != AdvertisingSetCallback.ADVERTISE_SUCCESS) {
                            emitError("Coded PHY advertising failed ($status)")
                        }
                    }

                    override fun onAdvertisingSetStopped(set: AdvertisingSet?) {
                        advertisingSet = null
                    }
                },
            )
        } catch (e: Exception) {
            emitError("Coded PHY advertising failed: ${e.message}")
        }
    }

    private fun startScanning() {
        val s = scanner ?: return
        try {
            val settings = ScanSettings.Builder()
                .setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY)
                .setLegacy(false)
                .setPhy(ScanSettings.PHY_LE_ALL_SUPPORTED)
                .build()
            s.startScan(null, settings, scanCallback)
            scanning = true
        } catch (e: Exception) {
            scanning = false
            emitError("Coded PHY scan failed: ${e.message}")
        }
    }

    private fun stopScanning() {
        scanning = false
        try {
            scanner?.stopScan(scanCallback)
        } catch (_: Exception) {
            // Already stopped.
        }
    }

    private fun stop() {
        running = false
        scanning = false
        handler.removeCallbacksAndMessages(null)
        stopScanning()
        try {
            advertiser?.stopAdvertisingSet(advertisingSetCallback)
        } catch (_: Exception) {
            // Already stopped.
        }
        advertisingSet = null

        for (link in ArrayList(links.values)) {
            closeLink(link)
        }
        links.clear()
        assemblies.clear()
        codedNegotiated = false
        emitStatus("off")
    }

    private val advertisingSetCallback = object : AdvertisingSetCallback() {}

    // ── Discovery ────────────────────────────────────────────────────

    private val scanCallback = object : ScanCallback() {
        override fun onScanResult(callbackType: Int, result: ScanResult) {
            val record = result.scanRecord
            val namedSahara = try {
                result.device.name == "Sahara"
            } catch (_: SecurityException) {
                false
            }
            val isSahara = record?.serviceUuids?.any {
                it.uuid == SERVICE_UUID
            } == true || record?.deviceName == "Sahara" || namedSahara

            if (!isSahara) return

            val address = result.device.address ?: return
            emitPeer(address, result.rssi)

            if (links.containsKey(address)) return
            if (links.size >= MAX_LINKS) return
            val now = System.currentTimeMillis()
            if (now - lastConnectAttempt < 2000) return
            lastConnectAttempt = now
            connect(result.device, address)
        }

        override fun onScanFailed(errorCode: Int) {
            emitError("Coded PHY scan failed ($errorCode)")
            scanning = false
        }
    }

    private fun connect(device: BluetoothDevice, address: String) {
        if (links.containsKey(address)) return
        val link = Link(device)
        links[address] = link
        try {
            val gatt = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                device.connectGatt(
                    context,
                    false,
                    gattCallback(address),
                    BluetoothDevice.TRANSPORT_LE,
                )
            } else {
                device.connectGatt(context, false, gattCallback(address))
            }
            if (gatt == null) {
                links.remove(address)
                emitError("Could not open a GATT link to $address")
                return
            }
            link.gatt = gatt
        } catch (e: Exception) {
            links.remove(address)
            emitError("GATT connect to $address failed: ${e.message}")
        }
    }

    private fun closeLink(link: Link) {
        link.ready = false
        link.writeQueue.clear()
        try {
            link.gatt?.disconnect()
            link.gatt?.close()
        } catch (_: Exception) {
            // Already gone.
        }
        link.gatt = null
        link.frameCharacteristic = null
    }

    // ── GATT client ──────────────────────────────────────────────────

    private fun gattCallback(address: String) = object : BluetoothGattCallback() {

        override fun onConnectionStateChange(gatt: BluetoothGatt, status: Int, newState: Int) {
            if (newState == BluetoothProfile.STATE_CONNECTED) {
                val link = links[address] ?: return
                try {
                    gatt.requestConnectionPriority(BluetoothGatt.CONNECTION_PRIORITY_HIGH)
                } catch (_: Exception) {
                }
                // The whole point of this link: ask for the long-range PHY.
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    try {
                        gatt.setPreferredPhy(
                            BluetoothDevice.PHY_LE_CODED,
                            BluetoothDevice.PHY_LE_CODED,
                            BluetoothDevice.PHY_OPTION_NO_PREFERRED,
                        )
                    } catch (e: Exception) {
                        emitError("Could not request the Coded PHY: ${e.message}")
                    }
                }
                try {
                    gatt.requestMtu(517)
                } catch (_: Exception) {
                }
                try {
                    @Suppress("DEPRECATION")
                    gatt.discoverServices()
                } catch (e: Exception) {
                    emitError("Service discovery failed: ${e.message}")
                }
                emitStatus(currentStatus())
            } else if (newState == BluetoothProfile.STATE_DISCONNECTED) {
                val link = links[address]
                if (link != null) {
                    closeLink(link)
                    links.remove(address)
                }
                emitStatus(currentStatus())
            }
        }

        override fun onMtuChanged(gatt: BluetoothGatt, mtu: Int, status: Int) {
            val link = links[address] ?: return
            val usable = (mtu - 3).coerceAtLeast(MIN_PAYLOAD)
            link.payload = usable
        }

        override fun onPhyUpdate(gatt: BluetoothGatt, txPhy: Int, rxPhy: Int, status: Int) {
            val link = links[address] ?: return
            val coded = status == BluetoothGatt.GATT_SUCCESS &&
                (rxPhy and BluetoothDevice.PHY_LE_CODED) != 0
            link.coded = coded
            if (coded) codedNegotiated = true
            emitPhy(coded)
            emitStatus(currentStatus())
        }

        override fun onServicesDiscovered(gatt: BluetoothGatt, status: Int) {
            val link = links[address] ?: return
            if (status != BluetoothGatt.GATT_SUCCESS) {
                emitError("Service discovery failed ($status)")
                return
            }
            val service = gatt.getService(SERVICE_UUID)
            val characteristic = service?.getCharacteristic(FRAME_UUID)
            if (characteristic == null) {
                emitError("Peer $address does not expose the Sahara frame characteristic")
                return
            }
            link.frameCharacteristic = characteristic
            try {
                gatt.setCharacteristicNotification(characteristic, true)
                val cccd = characteristic.getDescriptor(CCCD_UUID)
                if (cccd != null) {
                    @Suppress("DEPRECATION")
                    cccd.value = BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE
                    @Suppress("DEPRECATION")
                    gatt.writeDescriptor(cccd)
                }
                link.ready = true
                emitStatus(currentStatus())
            } catch (e: Exception) {
                emitError("Could not enable notifications: ${e.message}")
            }
        }

        @Deprecated("Deprecated in API 33")
        override fun onCharacteristicChanged(
            gatt: BluetoothGatt,
            characteristic: BluetoothGattCharacteristic,
        ) {
            @Suppress("DEPRECATION")
            val value = characteristic.value ?: return
            ingest(address, value)
        }

        override fun onCharacteristicChanged(
            gatt: BluetoothGatt,
            characteristic: BluetoothGattCharacteristic,
            value: ByteArray,
        ) {
            ingest(address, value)
        }

        override fun onCharacteristicWrite(
            gatt: BluetoothGatt,
            characteristic: BluetoothGattCharacteristic,
            status: Int,
        ) {
            val link = links[address] ?: return
            link.writing = false
            if (status != BluetoothGatt.GATT_SUCCESS) {
                emitError("Write to $address failed ($status)")
            }
            pump(link)
        }
    }

    // ── Sending ──────────────────────────────────────────────────────

    private fun send(frame: ByteArray): Int {
        var targets = 0
        for (link in ArrayList(links.values)) {
            if (!link.ready || link.gatt == null) continue
            targets++
            for (chunk in split(frame, link.payload)) {
                link.writeQueue.add(chunk)
            }
            pump(link)
        }
        if (targets == 0) {
            throw IllegalStateException("No Coded PHY peer is connected")
        }
        return targets
    }

    private fun pump(link: Link) {
        if (link.writing) return
        val gatt = link.gatt ?: return
        val characteristic = link.frameCharacteristic ?: return
        val chunk = link.writeQueue.poll() ?: return

        link.writing = true
        try {
            val ok = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                gatt.writeCharacteristic(
                    characteristic,
                    chunk,
                    BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT,
                ) == android.bluetooth.BluetoothStatusCodes.SUCCESS
            } else {
                @Suppress("DEPRECATION")
                characteristic.writeType = BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT
                @Suppress("DEPRECATION")
                characteristic.value = chunk
                @Suppress("DEPRECATION")
                gatt.writeCharacteristic(characteristic)
            }
            if (!ok) {
                link.writing = false
                emitError("Coded PHY write was rejected")
            }
        } catch (e: Exception) {
            link.writing = false
            emitError("Coded PHY write failed: ${e.message}")
        }
    }

    /** Same envelope as `FrameFragmenter` in `lib/net/fragmentation.dart`. */
    private fun split(frame: ByteArray, payload: Int): List<ByteArray> {
        val usable = (payload - CHUNK_HEADER).coerceAtLeast(1)
        val count = (frame.size + usable - 1) / usable
        if (count == 0 || count > 255) return emptyList()

        nextFragmentId = (nextFragmentId + 1) and 0xFFFF
        val id = nextFragmentId

        val out = ArrayList<ByteArray>(count)
        for (index in 0 until count) {
            val start = index * usable
            val end = minOf(start + usable, frame.size)
            val chunk = ByteArray(CHUNK_HEADER + (end - start))
            chunk[0] = CHUNK_MAGIC.toByte()
            chunk[1] = ((id shr 8) and 0xFF).toByte()
            chunk[2] = (id and 0xFF).toByte()
            chunk[3] = index.toByte()
            chunk[4] = count.toByte()
            System.arraycopy(frame, start, chunk, CHUNK_HEADER, end - start)
            out.add(chunk)
        }
        return out
    }

    // ── Receiving ────────────────────────────────────────────────────

    private fun ingest(address: String, chunk: ByteArray) {
        if (chunk.size < CHUNK_HEADER) return
        if ((chunk[0].toInt() and 0xFF) != CHUNK_MAGIC) return

        val id = ((chunk[1].toInt() and 0xFF) shl 8) or (chunk[2].toInt() and 0xFF)
        val index = chunk[3].toInt() and 0xFF
        val count = chunk[4].toInt() and 0xFF
        if (count == 0 || index >= count) return

        val now = System.currentTimeMillis()
        assemblies.entries.removeAll { now - it.value.createdAt > ASSEMBLY_TTL_MS }

        val key = "$address/$id"
        val assembly = assemblies.getOrPut(key) { Assembly(count) }
        if (assembly.count != count) {
            assemblies[key] = Assembly(count)
            return ingest(address, chunk)
        }
        if (assembly.parts[index] == null) {
            assembly.parts[index] = chunk.copyOfRange(CHUNK_HEADER, chunk.size)
            assembly.received++
        }
        if (assembly.received < assembly.count) return

        assemblies.remove(key)
        var total = 0
        for (part in assembly.parts) total += part?.size ?: 0
        if (total == 0) return
        val frame = ByteArray(total)
        var offset = 0
        for (part in assembly.parts) {
            if (part == null) return
            System.arraycopy(part, 0, frame, offset, part.size)
            offset += part.size
        }
        emitFrame(frame)
    }

    // ── Helpers ──────────────────────────────────────────────────────

    private fun currentStatus(): String = when {
        !running -> "off"
        links.values.any { it.ready } -> "connected"
        scanning -> "searching"
        else -> "idle"
    }

    private fun statusMap(): Map<String, Any?> = mapOf(
        "running" to running,
        "status" to currentStatus(),
        "peers" to links.values.count { it.ready },
        "coded" to codedNegotiated,
        "supported" to (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            (adapter?.isLeCodedPhySupported ?: false)),
    )

    private fun bluetoothAdapter(): BluetoothAdapter? {
        if (adapter != null) return adapter
        val manager = context.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager
        adapter = manager?.adapter
        return adapter
    }

    private fun granted(permission: String): Boolean =
        context.packageManager.checkPermission(
            permission,
            context.packageName,
        ) == PackageManager.PERMISSION_GRANTED

    private fun emitFrame(payload: ByteArray) {
        handler.post {
            eventSink?.success(mapOf("type" to "frame", "data" to payload))
        }
    }

    private fun emitPeer(address: String, rssi: Int) {
        handler.post {
            eventSink?.success(
                mapOf(
                    "type" to "peer",
                    "address" to address,
                    "rssi" to rssi,
                ),
            )
        }
    }

    private fun emitPhy(coded: Boolean) {
        handler.post {
            eventSink?.success(mapOf("type" to "phy", "coded" to coded))
        }
    }

    private fun emitStatus(status: String) {
        handler.post {
            eventSink?.success(
                mapOf(
                    "type" to "status",
                    "status" to status,
                    "peers" to links.values.count { it.ready },
                    "coded" to codedNegotiated,
                ),
            )
        }
    }

    private fun emitError(message: String) {
        handler.post {
            eventSink?.success(mapOf("type" to "error", "message" to message))
        }
    }
}
