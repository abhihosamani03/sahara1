package com.example.voice

import android.content.Context
import android.content.pm.PackageManager
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.wifi.aware.AttachCallback
import android.net.wifi.aware.DiscoverySession
import android.net.wifi.aware.DiscoverySessionCallback
import android.net.wifi.aware.PeerHandle
import android.net.wifi.aware.PublishConfig
import android.net.wifi.aware.PublishDiscoverySession
import android.net.wifi.aware.SubscribeConfig
import android.net.wifi.aware.SubscribeDiscoverySession
import android.net.wifi.aware.WifiAwareManager
import android.net.wifi.aware.WifiAwareNetworkInfo
import android.net.wifi.aware.WifiAwareNetworkSpecifier
import android.net.wifi.aware.WifiAwareSession
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
import kotlin.random.Random

/**
 * Wi-Fi Aware (NAN — Neighbour Awareness Networking) transport for Sahara.
 *
 * This is the third radio. It is genuinely different from Wi-Fi Direct:
 * no group owner election, no connection prompt, and no dependency on one
 * device being reachable as an AP — devices announce a service and discover
 * each other directly, then open a data path to that specific peer.
 *
 * The framework requires **both** sides to call `requestNetwork` with matching
 * specifiers before a data path exists, so the protocol is:
 *
 *  1. Every node publishes the `sahara` service *and* subscribes to it, so the
 *     roles are symmetric (PTT works both ways).
 *  2. Each publish carries an 8-byte random instance ID in the service-specific
 *     information. When two nodes discover each other, only the one with the
 *     smaller ID initiates — otherwise both would build a data path and the app
 *     would see every frame twice.
 *  3. The initiator sends a wake-up message and requests the network as the
 *     requester; the responder requests it from the message's `PeerHandle`.
 *  4. Once each side has a `Network`, the initiator connects to the responder's
 *     link-local IPv6 address on [PORT]; the responder accepts. Frames then flow
 *     as length-prefixed byte arrays, exactly like the Wi-Fi Direct transport,
 *     and the responder relays them to its other NAN peers.
 *
 * Requires Android 10 (API 29): `WifiAwareNetworkSpecifier.Builder` with a
 * peer handle and PSK only exists from there. Older devices report
 * "unsupported" and the caller keeps BLE + Wi-Fi Direct.
 */
class WifiAwarePlugin(
    private val context: Context,
    messenger: BinaryMessenger,
) : MethodChannel.MethodCallHandler, EventChannel.StreamHandler {

    private companion object {
        const val METHOD_CHANNEL = "itantra/wifiaware"
        const val EVENT_CHANNEL = "itantra/wifiaware/events"

        /** NAN service name advertised by every Sahara node. */
        const val SERVICE_NAME = "sahara-mesh"

        /** TCP port used inside the NAN data path. */
        const val PORT = 8989

        /** Shared passphrase for the data path (NAN itself is not encrypted). */
        const val PSK = "sahara-field-mesh-2026"

        /** Refuse absurd frame lengths from the wire. */
        const val MAX_FRAME_BYTES = 64 * 1024

        /** Maximum simultaneous NAN data paths. */
        const val MAX_PEERS = 4

        /** Re-publish/re-subscribe if discovery produced nothing for this long. */
        const val REANNOUNCE_MS = 30_000L

        /** How long the framework may take to build a data path. */
        const val DATA_PATH_TIMEOUT_MS = 30_000

        const val NEARBY_WIFI_DEVICES = "android.permission.NEARBY_WIFI_DEVICES"
    }

    private val handler = Handler(Looper.getMainLooper())
    private val methodChannel = MethodChannel(messenger, METHOD_CHANNEL)
    private val eventChannel = EventChannel(messenger, EVENT_CHANNEL)

    private var eventSink: EventChannel.EventSink? = null
    private var manager: WifiAwareManager? = null
    private var session: WifiAwareSession? = null
    private var publishSession: PublishDiscoverySession? = null
    private var subscribeSession: SubscribeDiscoverySession? = null

    private var running = false
    private var connecting = false
    private var requestedAt = 0L

    /** Random identity for the deterministic "who initiates" tie-break. */
    private val instanceId: ByteArray = ByteArray(8).also {
        Random.nextBytes(it)
    }

    private val writeLock = Any()
    private val clients = Collections.synchronizedList(mutableListOf<Client>())
    private val peerHandles = Collections.synchronizedSet(mutableSetOf<PeerHandle>())

    private var serverSocket: ServerSocket? = null

    private data class Client(val socket: Socket, val output: DataOutputStream)

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

    private fun capabilities(): Map<String, Any?> {
        val m = manager()
        val available = Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q &&
            m != null && m.isAvailable
        return mapOf(
            "supported" to available,
            "status" to if (available) currentStatus() else "unsupported",
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

        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            emitStatus("unsupported")
            emitError("Wi-Fi Aware needs Android 10 or newer")
            return false
        }
        val m = manager()
        if (m == null) {
            emitStatus("unsupported")
            return false
        }
        if (!m.isAvailable) {
            emitStatus("unsupported")
            emitError("Wi-Fi Aware is not available on this phone")
            return false
        }
        if (!hasPermissions()) {
            emitStatus("permission-denied")
            emitError("Wi-Fi Aware needs the Nearby devices permission")
            return false
        }

        manager = m
        running = true
        emitStatus("searching")

        try {
            m.attach(object : AttachCallback() {
                override fun onAttached(awareSession: WifiAwareSession) {
                    session = awareSession
                    publish()
                    subscribe()
                    scheduleReannounce()
                }

                override fun onAttachFailed() {
                    running = false
                    emitStatus("unavailable")
                    emitError("Could not attach to Wi-Fi Aware")
                }
            }, handler)
        } catch (e: SecurityException) {
            running = false
            emitError("Wi-Fi Aware needs the Nearby devices permission")
            return false
        } catch (e: Exception) {
            running = false
            emitError("Wi-Fi Aware attach failed: ${e.message}")
            return false
        }
        return true
    }

    private fun stop() {
        running = false
        connecting = false
        handler.removeCallbacksAndMessages(null)

        try {
            publishSession?.close()
        } catch (_: Exception) {
        }
        try {
            subscribeSession?.close()
        } catch (_: Exception) {
        }
        try {
            session?.close()
        } catch (_: Exception) {
        }
        publishSession = null
        subscribeSession = null
        session = null
        manager = null
        peerHandles.clear()
        teardownSockets()
        emitStatus("off")
    }

    private fun publish() {
        val s = session ?: return
        if (publishSession != null) return
        try {
            val config = PublishConfig.Builder()
                .setServiceName(SERVICE_NAME)
                .setServiceSpecificInfo(instanceId)
                .build()

            val callback = object : DiscoverySessionCallback() {
                override fun onPublishStarted(discovery: PublishDiscoverySession) {
                    publishSession = discovery
                    emitStatus(currentStatus())
                }

                override fun onSessionConfigFailed() {
                    emitError("Wi-Fi Aware publish was rejected")
                }

                override fun onSessionTerminated() {
                    publishSession = null
                }

                override fun onMessageReceived(peerHandle: PeerHandle, message: ByteArray) {
                    // The peer that loses the ID tie-break asks us to build a
                    // data path; respond from its handle.
                    peerHandles.add(peerHandle)
                    buildDataPath(peerHandle)
                    startServerIfNeeded()
                }
            }

            s.publish(config, callback, handler)
        } catch (e: Exception) {
            emitError("Wi-Fi Aware publish failed: ${e.message}")
        }
    }

    private fun subscribe() {
        val s = session ?: return
        if (subscribeSession != null) return
        try {
            val config = SubscribeConfig.Builder()
                .setServiceName(SERVICE_NAME)
                .build()

            val callback = object : DiscoverySessionCallback() {
                override fun onSubscribeStarted(discovery: SubscribeDiscoverySession) {
                    subscribeSession = discovery
                    emitStatus(currentStatus())
                }

                override fun onSessionConfigFailed() {
                    emitError("Wi-Fi Aware subscribe was rejected")
                }

                override fun onSessionTerminated() {
                    subscribeSession = null
                }

                override fun onServiceDiscovered(
                    peerHandle: PeerHandle,
                    serviceSpecificInfo: ByteArray,
                    matchFilter: List<ByteArray>,
                ) {
                    peerHandles.add(peerHandle)

                    // Only one side initiates, or both sides build a data path
                    // to the same peer and every frame arrives twice.
                    val theirs = serviceSpecificInfo
                    if (theirs.size >= 8 && compareInstance(theirs) > 0) {
                        // Our ID is larger: we respond (publisher callback).
                        return
                    }
                    connecting = true
                    requestedAt = System.currentTimeMillis()
                    emitStatus("connecting")

                    try {
                        subscribeSession?.sendMessage(peerHandle, 0, instanceId)
                    } catch (e: Exception) {
                        emitError("NAN discovery message failed: ${e.message}")
                    }
                    buildDataPath(peerHandle)
                }
            }

            s.subscribe(config, callback, handler)
        } catch (e: Exception) {
            emitError("Wi-Fi Aware subscribe failed: ${e.message}")
        }
    }

    /** Lexicographic comparison of our instance ID with the peer's. */
    private fun compareInstance(theirs: ByteArray): Int {
        for (i in instanceId.indices) {
            val a = instanceId[i].toInt() and 0xFF
            val b = theirs[i].toInt() and 0xFF
            if (a != b) return a - b
        }
        return 0
    }

    /**
     * Ask the framework for a NAN data path to one peer.
     *
     * Both ends must call this with matching port and passphrase; the requester
     * connects, the responder accepts.
     */
    private fun buildDataPath(peer: PeerHandle) {
        val discovery = subscribeSession ?: publishSession ?: return
        val cm = context.getSystemService(Context.CONNECTIVITY_SERVICE)
            as? ConnectivityManager ?: return

        try {
            val specifier = WifiAwareNetworkSpecifier.Builder(discovery, peer)
                .setPskPassphrase(PSK)
                .setPort(PORT)
                .build()

            val request = NetworkRequest.Builder()
                .addTransportType(NetworkCapabilities.TRANSPORT_WIFI_AWARE)
                .setNetworkSpecifier(specifier)
                .build()

            cm.requestNetwork(request, object : ConnectivityManager.NetworkCallback() {
                override fun onAvailable(network: Network) {
                    handler.post { connectThrough(network) }
                }

                override fun onUnavailable() {
                    emitError("Wi-Fi Aware data path was not established")
                    connecting = false
                    emitStatus(currentStatus())
                }

                override fun onLost(network: Network) {
                    emitStatus(currentStatus())
                }
            }, DATA_PATH_TIMEOUT_MS)
        } catch (e: Exception) {
            emitError("Wi-Fi Aware data path request failed: ${e.message}")
        }
    }

    /**
     * Open the transport socket on a live data path.
     *
     * The requester dials the responder's link-local IPv6 address; the responder
     * already has a listening socket. Either side may become the listener if the
     * socket is available, so this is decided by whether we already have one.
     */
    private fun connectThrough(network: Network) {
        if (!running) return

        val info = context.getSystemService(Context.CONNECTIVITY_SERVICE)
            ?.let { cm ->
                (cm as ConnectivityManager)
                    .getNetworkCapabilities(network)
                    ?.transportInfo as? WifiAwareNetworkInfo
            }

        val peerAddress = info?.peerIpv6Addr
        if (peerAddress == null) {
            // We are the responder: keep listening.
            startServerIfNeeded()
            emitStatus(currentStatus())
            return
        }

        startServerIfNeeded()

        Thread {
            try {
                val socket = network.socketFactory.createSocket() as Socket
                socket.tcpNoDelay = true
                socket.connect(InetSocketAddress(peerAddress, PORT), 5000)
                addClient(socket)
                connecting = false
            } catch (e: Exception) {
                emitError("Wi-Fi Aware connect failed: ${e.message}")
                connecting = false
                emitStatus(currentStatus())
            }
        }.apply { isDaemon = true }.start()
    }

    private fun startServerIfNeeded() {
        if (serverSocket != null || !running) return
        Thread {
            try {
                val ss = ServerSocket()
                ss.reuseAddress = true
                ss.bind(InetSocketAddress(PORT))
                serverSocket = ss
                while (running && !ss.isClosed) {
                    val socket = ss.accept()
                    socket.tcpNoDelay = true
                    addClient(socket)
                }
            } catch (_: Exception) {
                // Closed, or the port is already bound by a previous attempt.
            }
        }.apply { isDaemon = true }.start()
    }

    private fun addClient(socket: Socket) {
        val client = Client(socket, DataOutputStream(socket.getOutputStream()))
        clients.add(client)
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
                    // Relay to the other members of the NAN cluster.
                    broadcast(payload, except = socket)
                }
            } catch (_: Exception) {
                // Peer vanished.
            } finally {
                removeClient(client)
            }
        }.apply { isDaemon = true }.start()
    }

    private fun removeClient(client: Client) {
        clients.remove(client)
        try {
            client.socket.close()
        } catch (_: Exception) {
        }
        emitStatus(currentStatus(), peers = clients.size)
    }

    private fun broadcast(data: ByteArray, except: Socket?): Int {
        var sent = 0
        for (client in ArrayList(clients)) {
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
        }
        serverSocket = null
        for (client in ArrayList(clients)) {
            try {
                client.socket.close()
            } catch (_: Exception) {
            }
        }
        clients.clear()
    }

    private fun scheduleReannounce() {
        handler.postDelayed({
            if (!running) return@postDelayed
            if (clients.isEmpty()) {
                try {
                    publishSession?.close()
                } catch (_: Exception) {
                }
                try {
                    subscribeSession?.close()
                } catch (_: Exception) {
                }
                publishSession = null
                subscribeSession = null
                publish()
                subscribe()
                emitStatus("searching")
            }
            scheduleReannounce()
        }, REANNOUNCE_MS)
    }

    // ── Housekeeping ─────────────────────────────────────────────────

    private fun currentStatus(): String = when {
        !running -> "off"
        clients.isNotEmpty() -> "connected"
        connecting -> "connecting"
        publishSession != null || subscribeSession != null -> "searching"
        else -> "idle"
    }

    private fun statusMap(): Map<String, Any?> = mapOf(
        "running" to running,
        "status" to currentStatus(),
        "peers" to clients.size,
        "supported" to (manager?.isAvailable == true),
    )

    private fun manager(): WifiAwareManager? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return null
        manager = manager ?: (
            context.getSystemService(Context.WIFI_AWARE_SERVICE) as? WifiAwareManager
            )
        return manager
    }

    private fun hasPermissions(): Boolean {
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

    private fun emitStatus(status: String, peers: Int = clients.size) {
        handler.post {
            eventSink?.success(
                mapOf(
                    "type" to "status",
                    "status" to status,
                    "peers" to peers,
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
