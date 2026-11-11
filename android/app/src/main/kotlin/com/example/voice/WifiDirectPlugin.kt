package com.example.voice

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.net.wifi.WpsInfo
import android.net.wifi.p2p.WifiP2pConfig
import android.net.wifi.p2p.WifiP2pDevice
import android.net.wifi.p2p.WifiP2pManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.DataInputStream
import java.io.DataOutputStream
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.util.Collections

/**
 * Wi-Fi Direct (Wi-Fi P2P) transport for Sahara.
 *
 * This is the second radio alongside the BLE mesh, and it needs **no hotspot,
 * no router and no pairing**: the app negotiates a Wi-Fi Direct group with the
 * other phone, elects a group owner, and then carries iBFS frames over a
 * length-prefixed TCP socket inside that group.
 *
 * Design notes:
 *  - Every device is symmetric: both sides call discoverPeers() and connect().
 *    Wi-Fi Direct's own group-owner negotiation decides who owns the group, so
 *    there is no host/client mode to configure — PTT works both ways.
 *  - When the framework exposes both device addresses, the group-owner intent
 *    is biased deterministically (lexicographically smaller address asks to be
 *    owner) which makes negotiation converge on the first attempt. When the
 *    addresses are hidden (Android 6+ randomisation) both sides ask to be owner
 *    and the framework arbitrates.
 *  - If this device ends up owning a group that nobody joins, the group is
 *    torn down after [OWNER_IDLE_RESET_MS] so the two phones cannot get stuck
 *    in two separate one-member groups forever.
 *  - The group owner relays frames between its clients, so a 3-device cluster
 *    still works.
 *
 * Dart sees two channels:
 *   itantra/wifidirect          — start / stop / send / status
 *   itantra/wifidirect/events   — {type: status|frame|error, ...}
 */
class WifiDirectPlugin(
    private val context: Context,
    messenger: BinaryMessenger,
) : MethodChannel.MethodCallHandler, EventChannel.StreamHandler {

    private companion object {
        const val METHOD_CHANNEL = "itantra/wifidirect"
        const val EVENT_CHANNEL = "itantra/wifidirect/events"

        /** TCP port used inside the P2P group. */
        const val PORT = 8988

        /** Refuse absurd frame lengths from the wire. */
        const val MAX_FRAME_BYTES = 64 * 1024

        /** Re-run discovery on this cadence (P2P discovery sessions expire). */
        const val DISCOVER_INTERVAL_MS = 10_000L

        /** Minimum gap between group-formation attempts. */
        const val CONNECT_RETRY_MS = 8_000L

        /** Delay between asking for a discovery pass and reading the peers. */
        const val PEER_POLL_DELAY_MS = 2_000L

        /** An owner with no client for this long gives up its group. */
        const val OWNER_IDLE_RESET_MS = 25_000L

        const val NEARBY_WIFI_DEVICES = "android.permission.NEARBY_WIFI_DEVICES"
    }

    private val handler = Handler(Looper.getMainLooper())
    private val methodChannel = MethodChannel(messenger, METHOD_CHANNEL)
    private val eventChannel = EventChannel(messenger, EVENT_CHANNEL)

    private var manager: WifiP2pManager? = null
    private var p2pChannel: WifiP2pManager.Channel? = null
    private var eventSink: EventChannel.EventSink? = null
    private var receiver: BroadcastReceiver? = null

    private var running = false
    private var negotiating = false
    private var myAddress: String? = null
    private var lastConnectAttempt = 0L
    private var connected = false
    private var ownerSince = 0L

    private var serverSocket: ServerSocket? = null
    private var acceptThread: Thread? = null

    private val writeLock = Any()
    private val clients = Collections.synchronizedList(mutableListOf<Client>())

    private data class Client(val socket: Socket, val output: DataOutputStream)

    init {
        methodChannel.setMethodCallHandler(this)
        eventChannel.setStreamHandler(this)
    }

    // ── Method channel ───────────────────────────────────────────────

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
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
                if (data.size > MAX_FRAME_BYTES) {
                    result.error("ARG", "Frame too large: ${data.size}", null)
                    return
                }
                result.success(broadcast(data, except = null))
            }
            "status" -> result.success(statusMap())
            else -> result.notImplemented()
        }
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

        if (!hasDiscoveryPermission()) {
            emitStatus("permission-denied")
            emitError(
                "Wi-Fi Direct needs the Nearby devices permission " +
                    "(or Location on Android 12 and below).",
            )
            return false
        }

        val p2pManager =
            context.getSystemService(Context.WIFI_P2P_SERVICE) as? WifiP2pManager
        if (p2pManager == null) {
            emitStatus("unsupported")
            return false
        }

        val channel = try {
            p2pManager.initialize(context, Looper.getMainLooper(), null)
        } catch (e: Exception) {
            emitError("WifiP2pManager.initialize failed: ${e.message}")
            null
        }
        if (channel == null) {
            emitStatus("unsupported")
            return false
        }

        manager = p2pManager
        p2pChannel = channel

        val filter = IntentFilter().apply {
            addAction(WifiP2pManager.WIFI_P2P_STATE_CHANGED_ACTION)
            addAction(WifiP2pManager.WIFI_P2P_PEERS_CHANGED_ACTION)
            addAction(WifiP2pManager.WIFI_P2P_CONNECTION_CHANGED_ACTION)
            addAction(WifiP2pManager.WIFI_P2P_THIS_DEVICE_CHANGED_ACTION)
        }
        receiver = object : BroadcastReceiver() {
            override fun onReceive(ctx: Context?, intent: Intent?) {
                if (intent != null) handleIntent(intent)
            }
        }
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                context.registerReceiver(
                    receiver,
                    filter,
                    Context.RECEIVER_NOT_EXPORTED,
                )
            } else {
                @Suppress("UnspecifiedRegisterReceiverFlag")
                context.registerReceiver(receiver, filter)
            }
        } catch (e: Exception) {
            emitError("registerReceiver failed: ${e.message}")
            return false
        }

        running = true
        emitStatus("searching")
        handler.post(discoverLoop)
        return true
    }

    private fun stop() {
        running = false
        negotiating = false
        connected = false
        ownerSince = 0L
        handler.removeCallbacksAndMessages(null)
        teardownSockets()

        receiver?.let {
            try {
                context.unregisterReceiver(it)
            } catch (_: Exception) {
                // Already unregistered.
            }
        }
        receiver = null

        try {
            manager?.removeGroup(p2pChannel, null)
        } catch (_: Exception) {
            // Group may already be gone.
        }

        manager = null
        p2pChannel = null
        emitStatus("off")
    }

    // ── Discovery + group formation ──────────────────────────────────

    private val discoverLoop = object : Runnable {
        override fun run() {
            if (!running) return
            reapIdleOwnerGroup()
            discoverPeers()
            // Poll the peer list directly instead of waiting only for
            // WIFI_P2P_PEERS_CHANGED_ACTION. Some OEM stacks never broadcast
            // that action, which leaves discovery stuck at "searching" with
            // zero peers forever. discoverPeers() needs a moment to produce
            // results, so the poll is offset slightly.
            handler.postDelayed({ requestPeers() }, PEER_POLL_DELAY_MS)
            handler.postDelayed(this, DISCOVER_INTERVAL_MS)
        }
    }

    private fun discoverPeers() {
        val m = manager ?: return
        val c = p2pChannel ?: return
        try {
            m.discoverPeers(c, object : WifiP2pManager.ActionListener {
                override fun onSuccess() {
                    if (currentStatus() == "searching") emitStatus("searching")
                }

                override fun onFailure(reason: Int) {
                    emitError("discoverPeers failed ($reason)")
                    if (reason == WifiP2pManager.BUSY) {
                        // A stale group blocks discovery — clear it.
                        releaseGroup("discovery busy")
                    }
                }
            })
        } catch (e: SecurityException) {
            emitError("discoverPeers needs the Nearby devices permission")
        }
    }

    private fun requestPeers() {
        val m = manager ?: return
        val c = p2pChannel ?: return
        try {
            m.requestPeers(c) { peerList ->
                val available = peerList.deviceList.filter {
                    it.status == WifiP2pDevice.AVAILABLE ||
                        it.status == WifiP2pDevice.INVITED
                }
                if (available.isEmpty()) {
                    if (!connected) emitStatus("no-peers")
                    return@requestPeers
                }
                if (!connected) {
                    emitStatus("peers-found", devices = available.size)
                }
                maybeConnect(available)
            }
        } catch (e: SecurityException) {
            emitError("requestPeers needs the Nearby devices permission")
        }
    }

    /**
     * Attempt group formation with one of the discovered devices.
     *
     * Both phones run this code, so the two connect() calls race; the framework
     * arbitrates group ownership. A small randomised delay desynchronises the
     * two sides, which markedly improves first-attempt success on OEM stacks
     * that dislike simultaneous negotiation.
     */
    private fun maybeConnect(devices: List<WifiP2pDevice>) {
        if (negotiating || connected) return
        val now = System.currentTimeMillis()
        if (now - lastConnectAttempt < CONNECT_RETRY_MS) return
        val target = devices.firstOrNull() ?: return

        lastConnectAttempt = now
        negotiating = true

        val mine = sanitizeAddress(myAddress)
        val theirs = sanitizeAddress(target.deviceAddress)
        val wantOwner = if (mine != null && theirs != null) {
            // Deterministic split — both sides compute the same winner, so
            // negotiation converges immediately.
            mine < theirs
        } else {
            // Addresses hidden by the OS: let the framework arbitrate.
            true
        }

        val config = WifiP2pConfig().apply {
            deviceAddress = target.deviceAddress
            @Suppress("DEPRECATION")
            wps.setup = WpsInfo.PBC
            groupOwnerIntent = if (wantOwner) 15 else 0
        }

        val stagger = (System.currentTimeMillis() % 600).toLong()
        handler.postDelayed({
            if (!running || connected) {
                negotiating = false
                return@postDelayed
            }
            try {
                manager?.connect(p2pChannel, config, object : WifiP2pManager.ActionListener {
                    override fun onSuccess() = emitStatus("negotiating")

                    override fun onFailure(reason: Int) {
                        negotiating = false
                        emitError("group formation failed ($reason)")
                        if (reason == WifiP2pManager.BUSY) releaseGroup("busy")
                    }
                })
            } catch (e: SecurityException) {
                negotiating = false
                emitError("connect needs the Nearby devices permission")
            }
        }, stagger)
    }

    private fun releaseGroup(reason: String) {
        negotiating = false
        ownerSince = 0L
        try {
            manager?.removeGroup(p2pChannel, object : WifiP2pManager.ActionListener {
                override fun onSuccess() {}

                override fun onFailure(reason2: Int) {
                    manager?.cancelConnect(p2pChannel, null)
                }
            })
        } catch (_: Exception) {
            // Ignore — the next discovery round retries anyway.
        }
        teardownSockets()
        connected = false
        emitStatus("searching")
    }

    // ── Connection handling ──────────────────────────────────────────

    private fun requestConnection() {
        val m = manager ?: return
        val c = p2pChannel ?: return
        try {
            m.requestConnectionInfo(c) { info ->
                if (!info.groupFormed) {
                    if (connected) {
                        teardownSockets()
                        connected = false
                        emitStatus("searching")
                    }
                    return@requestConnectionInfo
                }
                negotiating = false
                val ownerAddress = info.groupOwnerAddress?.hostAddress
                if (info.isGroupOwner) {
                    startServer()
                    connected = clients.isNotEmpty()
                    emitStatus(if (connected) "connected" else "owner-waiting")
                } else if (ownerAddress != null) {
                    connectToOwner(ownerAddress, attempt = 0)
                } else {
                    emitError("Group formed but owner address is unknown")
                }
            }
        } catch (e: SecurityException) {
            emitError("requestConnectionInfo needs the Nearby devices permission")
        }
    }

    private fun startServer() {
        if (serverSocket != null) return
        try {
            val ss = ServerSocket()
            ss.reuseAddress = true
            ss.bind(InetSocketAddress(PORT))
            serverSocket = ss
            ownerSince = System.currentTimeMillis()
            acceptThread = Thread {
                while (running && !ss.isClosed) {
                    try {
                        val socket = ss.accept()
                        socket.tcpNoDelay = true
                        addClient(socket)
                    } catch (_: Exception) {
                        break
                    }
                }
            }.apply {
                isDaemon = true
                start()
            }
        } catch (e: Exception) {
            emitError("Could not open the group socket: ${e.message}")
        }
    }

    private fun connectToOwner(host: String, attempt: Int) {
        Thread {
            try {
                val socket = Socket()
                socket.tcpNoDelay = true
                socket.connect(InetSocketAddress(host, PORT), 4000)
                addClient(socket)
                negotiating = false
            } catch (e: Exception) {
                emitError("Connecting to the group owner failed: ${e.message}")
                if (running && attempt < 6) {
                    handler.postDelayed(
                        { connectToOwner(host, attempt + 1) },
                        2000L,
                    )
                }
            }
        }.apply {
            isDaemon = true
            start()
        }
    }

    private fun addClient(socket: Socket) {
        val client = Client(socket, DataOutputStream(socket.getOutputStream()))
        clients.add(client)
        connected = true
        emitStatus("connected", peers = clients.size)

        Thread {
            try {
                val input = DataInputStream(socket.getInputStream())
                while (running && !socket.isClosed) {
                    val length = input.readInt()
                    if (length <= 0 || length > MAX_FRAME_BYTES) break
                    val payload = ByteArray(length)
                    input.readFully(payload)
                    emitFrame(payload)
                    // Relay to the other members of the group (never back to
                    // the sender): the group owner becomes a repeater.
                    broadcast(payload, except = socket)
                }
            } catch (_: Exception) {
                // Socket closed or peer vanished.
            } finally {
                removeClient(client)
            }
        }.apply {
            isDaemon = true
            start()
        }
    }

    private fun removeClient(client: Client) {
        clients.remove(client)
        try {
            client.socket.close()
        } catch (_: Exception) {
            // Already closed.
        }
        if (clients.isEmpty()) {
            connected = false
            emitStatus(if (serverSocket != null) "owner-waiting" else "searching")
        } else {
            emitStatus("connected", peers = clients.size)
        }
    }

    private fun broadcast(data: ByteArray, except: Socket?): Int {
        var sent = 0
        val snapshot = ArrayList(clients)
        for (client in snapshot) {
            if (client.socket === except) continue
            try {
                synchronized(writeLock) {
                    client.output.writeInt(data.size)
                    client.output.write(data)
                    client.output.flush()
                }
                sent++
            } catch (_: Exception) {
                removeClient(client)
            }
        }
        return sent
    }

    private fun teardownSockets() {
        try {
            serverSocket?.close()
        } catch (_: Exception) {
            // Ignore.
        }
        serverSocket = null
        acceptThread = null
        val snapshot = ArrayList(clients)
        clients.clear()
        for (client in snapshot) {
            try {
                client.socket.close()
            } catch (_: Exception) {
                // Ignore.
            }
        }
    }

    // ── Broadcast handling ───────────────────────────────────────────

    private fun handleIntent(intent: Intent) {
        when (intent.action) {
            WifiP2pManager.WIFI_P2P_STATE_CHANGED_ACTION -> {
                val state = intent.getIntExtra(WifiP2pManager.EXTRA_WIFI_STATE, -1)
                if (state != WifiP2pManager.WIFI_P2P_STATE_ENABLED) {
                    emitStatus("wifi-disabled")
                }
            }

            WifiP2pManager.WIFI_P2P_PEERS_CHANGED_ACTION -> requestPeers()

            WifiP2pManager.WIFI_P2P_CONNECTION_CHANGED_ACTION ->
                requestConnection()

            WifiP2pManager.WIFI_P2P_THIS_DEVICE_CHANGED_ACTION -> {
                @Suppress("DEPRECATION")
                val device = intent.getParcelableExtra<WifiP2pDevice>(
                    WifiP2pManager.EXTRA_WIFI_P2P_DEVICE,
                )
                if (device != null) myAddress = device.deviceAddress
            }
        }
    }

    // ── Housekeeping ─────────────────────────────────────────────────

    /** Called from the discovery loop tick to drop a group nobody joined. */
    private fun reapIdleOwnerGroup() {
        if (serverSocket == null || clients.isNotEmpty()) {
            ownerSince = System.currentTimeMillis()
            return
        }
        if (ownerSince == 0L) {
            ownerSince = System.currentTimeMillis()
            return
        }
        if (System.currentTimeMillis() - ownerSince > OWNER_IDLE_RESET_MS) {
            emitStatus("owner-reset")
            releaseGroup("no clients joined the group")
        }
    }

    private fun currentStatus(): String = when {
        !running -> "off"
        !hasDiscoveryPermission() -> "permission-denied"
        clients.isNotEmpty() -> "connected"
        serverSocket != null -> "owner-waiting"
        negotiating -> "negotiating"
        else -> "searching"
    }

    private fun statusMap(): Map<String, Any?> = mapOf(
        "running" to running,
        "status" to currentStatus(),
        "peers" to clients.size,
        "isOwner" to (serverSocket != null),
    )

    private fun hasDiscoveryPermission(): Boolean {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            if (granted(NEARBY_WIFI_DEVICES)) return true
        }
        return granted(android.Manifest.permission.ACCESS_FINE_LOCATION)
    }

    private fun granted(permission: String): Boolean =
        context.packageManager.checkPermission(
            permission,
            context.packageName,
        ) == PackageManager.PERMISSION_GRANTED

    private fun sanitizeAddress(address: String?): String? {
        if (address.isNullOrEmpty()) return null
        val normalised = address.lowercase()
        if (normalised == "02:00:00:00:00:00") return null
        if (normalised == "00:00:00:00:00:00") return null
        return normalised
    }

    private fun emitStatus(status: String, devices: Int = 0, peers: Int = clients.size) {
        handler.post {
            eventSink?.success(
                mapOf(
                    "type" to "status",
                    "status" to status,
                    "peers" to peers,
                    "devices" to devices,
                    "isOwner" to (serverSocket != null),
                ),
            )
        }
    }

    private fun emitFrame(payload: ByteArray) {
        handler.post {
            eventSink?.success(mapOf("type" to "frame", "data" to payload))
        }
    }

    private fun emitError(message: String) {
        handler.post {
            eventSink?.success(mapOf("type" to "error", "message" to message))
        }
    }
}
