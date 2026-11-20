package jp.kairanban.kairanban.ble

import android.annotation.SuppressLint
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattDescriptor
import android.bluetooth.BluetoothGattServer
import android.bluetooth.BluetoothGattServerCallback
import android.bluetooth.BluetoothGattService
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.bluetooth.BluetoothStatusCodes
import android.bluetooth.le.AdvertiseCallback
import android.bluetooth.le.AdvertiseData
import android.bluetooth.le.AdvertiseSettings
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanFilter
import android.bluetooth.le.ScanRecord
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import android.os.ParcelUuid
import android.os.PowerManager
import android.os.SystemClock
import android.util.Log
import java.util.UUID

/**
 * BLE エンジン: 広告 + スキャン + GATT サーバ（peripheral）+ GATT クライアント（central）。
 *
 * 仕様は docs/02_protocol.md §1 と docs/03_architecture.md §3「ネイティブ側の責務」に従う。
 * 可変状態は全て専用の HandlerThread（エンジンスレッド）上でだけ触る。OS のコールバックは
 * 全てエンジンスレッドへ移してから処理する。Dart 向けイベントは [Listener] に渡す
 * （呼び出しはエンジンスレッド。メインスレッドへの移送は BleBridge が行う）。
 *
 * 権限は BleBridge が `start` 前に確認する（API 31+: SCAN/ADVERTISE/CONNECT、以下: FINE_LOCATION）。
 */
@SuppressLint("MissingPermission")
class BleEngine(context: Context, private val listener: Listener) {

    interface Listener {
        /** エンジンスレッドから呼ばれる。 */
        fun onEngineEvent(event: Map<String, Any?>)
    }

    /** `start` の引数。 */
    class Config(
        val serviceUuid: UUID,
        val rxUuid: UUID,
        val txUuid: UUID,
        val nodeId: ByteArray,
        val lowPower: Boolean,
    ) {
        fun withLowPower(value: Boolean): Config = Config(serviceUuid, rxUuid, txUuid, nodeId, value)

        fun sameGatt(other: Config?): Boolean =
            other != null && other.serviceUuid == serviceUuid &&
                other.rxUuid == rxUuid && other.txUuid == txUuid
    }

    /** 1 本の GATT 接続。 */
    private class Link(val id: Int, val peerId: String, val initiator: Boolean) {
        var device: BluetoothDevice? = null
        var gatt: BluetoothGatt? = null
        var rx: BluetoothGattCharacteristic? = null
        var tx: BluetoothGattCharacteristic? = null
        var mtu = DEFAULT_MTU
        var connected = false
        var discovering = false
        var opened = false
        var finished = false
        var retried133 = false
        var writeAttempts = 0
        var pendingSend: ((String?) -> Unit)? = null
        var sendTimeout: Runnable? = null
        var connectTimeout: Runnable? = null
        var mtuFallback: Runnable? = null
        var closeFallback: Runnable? = null

        /** peripheral 側: MTU の知らせを待ってから linkOpened を出す（その間の受信は溜める）。 */
        var openPending = false
        var openTimeout: Runnable? = null
        val earlyData = ArrayList<ByteArray>()
    }

    private val appContext: Context = context.applicationContext
    private val manager: BluetoothManager? = appContext.getSystemService(BluetoothManager::class.java)
    private val adapter: BluetoothAdapter? = manager?.adapter
    private val thread = HandlerThread("kairanban-ble").also { it.start() }
    private val handler = Handler(thread.looper)

    /**
     * 画面が消えている間も、接続・同期の途中で CPU が眠ってタイマー（接続・送信のタイムアウト、
     * Dart の同期の見直し）が止まらないようにする部分ウェイクロック。BLE の出来事があるたびに
     * 期限付きで取り直し、何も起きなければ期限で自動的に放す。
     */
    private val wakeLock: PowerManager.WakeLock? = try {
        appContext.getSystemService(PowerManager::class.java)
            ?.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "kairanban:ble")
            ?.apply { setReferenceCounted(false) }
    } catch (e: RuntimeException) {
        null
    }

    /** 端末が BLE に対応しているか。 */
    val isSupported: Boolean =
        adapter != null && appContext.packageManager.hasSystemFeature(PackageManager.FEATURE_BLUETOOTH_LE)

    @Volatile
    var running: Boolean = false
        private set

    @Volatile
    var poweredOn: Boolean = false
        private set

    @Volatile
    var scanning: Boolean = false
        private set

    @Volatile
    var advertising: Boolean = false
        private set

    // ---- 以下はエンジンスレッド専用 ----
    private var config: Config? = null
    private var nextLinkId = 1
    private val links = HashMap<Int, Link>()
    private val gattLinks = HashMap<BluetoothGatt, Link>()
    private val serverLinks = HashMap<String, Link>()
    private val serverMtu = HashMap<String, Int>()
    private var gattServer: BluetoothGattServer? = null
    private var txCharacteristic: BluetoothGattCharacteristic? = null
    private var serviceReady = false
    private var serverRetryPending = false
    private var advertiseRequested = false
    private var advertisePending = false
    private var scanPending = false
    private val scanStartTimes = ArrayDeque<Long>()
    private val knownDevices = HashMap<String, BluetoothDevice>()
    private val deviceSeen = HashMap<String, Long>()
    private val lastDiscovered = HashMap<String, Long>()
    private var lastState: Triple<Boolean, Boolean, Boolean>? = null

    private val adapterReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            if (intent.action != BluetoothAdapter.ACTION_STATE_CHANGED) return
            val state = intent.getIntExtra(BluetoothAdapter.EXTRA_STATE, BluetoothAdapter.ERROR)
            handler.post { onAdapterStateChanged(state) }
        }
    }

    init {
        val filter = IntentFilter(BluetoothAdapter.ACTION_STATE_CHANGED)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            appContext.registerReceiver(adapterReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            appContext.registerReceiver(adapterReceiver, filter)
        }
        poweredOn = adapter?.state == BluetoothAdapter.STATE_ON
    }

    // ================================================================ 公開 API（任意のスレッド）

    /** 現在状態の `state` イベント（permission は BleBridge が補う）。 */
    fun currentStateEvent(): Map<String, Any?> = mapOf(
        "type" to "state",
        "poweredOn" to poweredOn,
        "scanning" to scanning,
        "advertising" to advertising,
    )

    /** 診断ログを Dart に流す。 */
    fun log(message: String) {
        Log.d(TAG, message)
        emit("log", "message" to message)
    }

    fun start(config: Config) {
        handler.post {
            val previous = this.config
            this.config = config
            if (running) {
                // 二重 start は設定の更新として扱う。
                if (poweredOn) {
                    stopScanning()
                    stopAdvertising()
                    if (!config.sameGatt(previous)) {
                        closeAllLinks("restarted")
                        closeServer()
                    }
                    startRadios()
                }
                publishState(force = true)
                return@post
            }
            running = true
            poweredOn = adapter?.state == BluetoothAdapter.STATE_ON
            log("BLE を開始します（lowPower=${config.lowPower}）")
            if (poweredOn) {
                startRadios()
            } else {
                log("Bluetooth がオフのため、オンになるまで待ちます")
            }
            publishState(force = true)
        }
    }

    fun stop() {
        handler.post {
            if (!running) return@post
            running = false
            stopScanning()
            stopAdvertising()
            closeAllLinks("stopped")
            closeServer()
            releaseWake()
            log("BLE を停止しました")
            publishState(force = true)
        }
    }

    fun setLowPower(lowPower: Boolean) {
        handler.post {
            val current = config ?: return@post
            if (current.lowPower == lowPower) return@post
            config = current.withLowPower(lowPower)
            log(if (lowPower) "省電力モードに切り替えます" else "通常モードに切り替えます")
            if (running && poweredOn) {
                stopScanning()
                stopAdvertising()
                startAdvertising()
                startScanning()
            }
        }
    }

    fun connect(peerId: String) {
        handler.post { connectInternal(peerId) }
    }

    /** 1 チャンク送信。スタックに渡し終えたら callback(null)、失敗なら callback(理由)。 */
    fun send(linkId: Int, data: ByteArray, callback: (String?) -> Unit) {
        handler.post { sendInternal(linkId, data, callback) }
    }

    fun close(linkId: Int) {
        handler.post {
            val link = links[linkId]
            if (link == null) {
                Log.d(TAG, "close: 不明なリンク #$linkId")
            } else {
                finishLink(link, "closed")
            }
        }
    }

    // ================================================================ アダプタ状態

    private fun onAdapterStateChanged(state: Int) {
        when (state) {
            BluetoothAdapter.STATE_ON -> {
                if (poweredOn) return
                poweredOn = true
                log("Bluetooth がオンになりました")
                if (running) startRadios()
                publishState(force = true)
            }
            BluetoothAdapter.STATE_TURNING_OFF, BluetoothAdapter.STATE_OFF -> {
                val wasOn = poweredOn
                poweredOn = false
                closeAllLinks("bluetooth_off")
                stopScanning()
                stopAdvertising()
                closeServer()
                if (wasOn) log("Bluetooth がオフになりました")
                publishState(force = wasOn)
            }
        }
    }

    private fun startRadios() {
        if (gattServer == null) {
            openServer() // 広告は onServiceAdded 後に開始する
        } else if (serviceReady) {
            startAdvertising()
        }
        startScanning()
    }

    // ================================================================ スキャン

    private val scanCallback = object : ScanCallback() {
        override fun onScanResult(callbackType: Int, result: ScanResult) {
            handler.post { handleScanResult(result) }
        }

        override fun onBatchScanResults(results: List<ScanResult>) {
            handler.post { results.forEach(::handleScanResult) }
        }

        override fun onScanFailed(errorCode: Int) {
            handler.post { handleScanFailed(errorCode) }
        }
    }

    private val scanRestartRunnable = Runnable {
        if (!running || !poweredOn) return@Runnable
        // 連続スキャンは 30 分（実質 10 分）で機会的モードに落とされるので 9 分ごとに張り直す。
        Log.d(TAG, "スキャンを張り直します")
        stopScanning()
        startScanning()
    }

    private fun startScanning() {
        val cfg = config ?: return
        if (!running || !poweredOn || scanning || scanPending) return
        val scanner = adapter?.bluetoothLeScanner
        if (scanner == null) {
            log("スキャナを取得できません")
            scheduleScanRetry(SCAN_RETRY_MS)
            return
        }
        // 30 秒に 5 回までの開始制限を守る。
        val now = SystemClock.elapsedRealtime()
        while (scanStartTimes.isNotEmpty() && now - scanStartTimes.first() > SCAN_QUOTA_WINDOW_MS) {
            scanStartTimes.removeFirst()
        }
        if (scanStartTimes.size >= SCAN_QUOTA_COUNT) {
            val wait = SCAN_QUOTA_WINDOW_MS - (now - scanStartTimes.first()) + 500L
            log("スキャン開始回数の上限のため ${wait}ms 待ちます")
            scheduleScanRetry(wait)
            return
        }
        val filters = listOf(
            ScanFilter.Builder().setServiceUuid(ParcelUuid(cfg.serviceUuid)).build(),
            // iOS の背景広告（overflow area）: Apple 製造者データ、先頭バイト 0x01
            ScanFilter.Builder()
                .setManufacturerData(
                    APPLE_COMPANY_ID,
                    byteArrayOf(APPLE_OVERFLOW_TYPE),
                    byteArrayOf(0xFF.toByte()),
                )
                .build(),
        )
        val settings = ScanSettings.Builder()
            .setScanMode(
                if (cfg.lowPower) ScanSettings.SCAN_MODE_LOW_POWER else ScanSettings.SCAN_MODE_BALANCED,
            )
            .setCallbackType(ScanSettings.CALLBACK_TYPE_ALL_MATCHES)
            .setMatchMode(ScanSettings.MATCH_MODE_AGGRESSIVE)
            .setNumOfMatches(ScanSettings.MATCH_NUM_MAX_ADVERTISEMENT)
            .setReportDelay(0)
            .build()
        try {
            scanner.startScan(filters, settings, scanCallback)
        } catch (e: RuntimeException) {
            log("スキャン開始に失敗: ${e.message}")
            scheduleScanRetry(SCAN_RETRY_MS)
            return
        }
        scanStartTimes.addLast(now)
        scanning = true
        handler.removeCallbacks(scanRestartRunnable)
        handler.postDelayed(scanRestartRunnable, SCAN_RESTART_MS)
        publishState()
    }

    private fun scheduleScanRetry(delayMs: Long) {
        if (scanPending) return
        scanPending = true
        handler.postDelayed({
            scanPending = false
            startScanning()
        }, delayMs)
    }

    private fun stopScanning() {
        handler.removeCallbacks(scanRestartRunnable)
        if (!scanning) return
        scanning = false
        try {
            adapter?.bluetoothLeScanner?.stopScan(scanCallback)
        } catch (e: RuntimeException) {
            Log.w(TAG, "stopScan に失敗", e)
        }
        publishState()
    }

    private fun handleScanFailed(code: Int) {
        if (code == ScanCallback.SCAN_FAILED_ALREADY_STARTED) {
            scanning = true
            publishState()
            return
        }
        scanning = false
        handler.removeCallbacks(scanRestartRunnable)
        log("スキャンに失敗しました (${scanErrorName(code)})")
        if (running && poweredOn) {
            scheduleScanRetry(
                if (code == SCAN_FAILED_TOO_FREQUENTLY) SCAN_QUOTA_WINDOW_MS else SCAN_RETRY_MS,
            )
        }
        publishState()
    }

    private fun handleScanResult(result: ScanResult) {
        val cfg = config ?: return
        if (!running) return
        val device = result.device
        val address = device.address
        val record = result.scanRecord
        val hasService = record?.serviceUuids?.contains(ParcelUuid(cfg.serviceUuid)) == true
        val viaApple = !hasService && isAppleOverflow(record)
        if (!hasService && !viaApple) return

        val now = SystemClock.elapsedRealtime()
        knownDevices[address] = device
        deviceSeen[address] = now
        pruneCaches(now)

        // 同じ端末の連続通知は 2 秒に 1 回に間引く。
        val last = lastDiscovered[address]
        if (last != null && now - last < DISCOVER_DEDUP_MS) return
        lastDiscovered[address] = now
        // Dart が接続を判断するまで CPU を起こしておく（画面オフでも接続が始められるように）。
        keepAwake(WAKE_DISCOVERY_MS)
        emit("discovered", "peerId" to address, "rssi" to result.rssi, "viaApple" to viaApple)
    }

    private fun isAppleOverflow(record: ScanRecord?): Boolean {
        val data = record?.getManufacturerSpecificData(APPLE_COMPANY_ID) ?: return false
        return data.isNotEmpty() && data[0] == APPLE_OVERFLOW_TYPE
    }

    private fun pruneCaches(now: Long) {
        if (lastDiscovered.size > CACHE_PRUNE_THRESHOLD) {
            lastDiscovered.values.removeAll { now - it > DISCOVER_DEDUP_MS * 5 }
        }
        if (knownDevices.size > CACHE_PRUNE_THRESHOLD) {
            val stale = deviceSeen.filterValues { now - it > DEVICE_CACHE_TTL_MS }.keys
            for (address in stale) {
                knownDevices.remove(address)
                deviceSeen.remove(address)
            }
        }
    }

    // ================================================================ 広告

    private val advertiseCallback = object : AdvertiseCallback() {
        override fun onStartSuccess(settingsInEffect: AdvertiseSettings?) {
            handler.post {
                advertising = true
                log("広告を開始しました")
                publishState()
            }
        }

        override fun onStartFailure(errorCode: Int) {
            handler.post { handleAdvertiseFailed(errorCode) }
        }
    }

    private fun startAdvertising() {
        val cfg = config ?: return
        if (!running || !poweredOn || advertising || advertiseRequested || advertisePending) return
        val advertiser = adapter?.bluetoothLeAdvertiser
        if (advertiser == null) {
            log("この端末は BLE 広告（peripheral）に対応していません")
            return
        }
        val settings = AdvertiseSettings.Builder()
            .setAdvertiseMode(
                if (cfg.lowPower) {
                    AdvertiseSettings.ADVERTISE_MODE_LOW_POWER
                } else {
                    AdvertiseSettings.ADVERTISE_MODE_BALANCED
                },
            )
            .setTxPowerLevel(AdvertiseSettings.ADVERTISE_TX_POWER_HIGH)
            .setConnectable(true)
            .setTimeout(0)
            .build()
        // Service UUID のみ。端末名・製造者データは載せない（docs/02_protocol.md §1）。
        val data = AdvertiseData.Builder()
            .addServiceUuid(ParcelUuid(cfg.serviceUuid))
            .setIncludeDeviceName(false)
            .setIncludeTxPowerLevel(false)
            .build()
        try {
            advertiser.startAdvertising(settings, data, advertiseCallback)
            advertiseRequested = true
        } catch (e: RuntimeException) {
            log("広告開始に失敗: ${e.message}")
            scheduleAdvertiseRetry()
        }
    }

    private fun scheduleAdvertiseRetry() {
        if (advertisePending) return
        advertisePending = true
        handler.postDelayed({
            advertisePending = false
            startAdvertising()
        }, ADVERTISE_RETRY_MS)
    }

    private fun stopAdvertising() {
        if (!advertising && !advertiseRequested) return
        advertising = false
        advertiseRequested = false
        try {
            adapter?.bluetoothLeAdvertiser?.stopAdvertising(advertiseCallback)
        } catch (e: RuntimeException) {
            Log.w(TAG, "stopAdvertising に失敗", e)
        }
        publishState()
    }

    private fun handleAdvertiseFailed(code: Int) {
        if (code == AdvertiseCallback.ADVERTISE_FAILED_ALREADY_STARTED) {
            advertising = true
            publishState()
            return
        }
        advertising = false
        advertiseRequested = false
        log("広告の開始に失敗しました (${advertiseErrorName(code)})")
        if (running && poweredOn && code != AdvertiseCallback.ADVERTISE_FAILED_FEATURE_UNSUPPORTED) {
            scheduleAdvertiseRetry()
        }
        publishState()
    }

    // ================================================================ GATT サーバ（peripheral 側）

    private val serverCallback = object : BluetoothGattServerCallback() {
        override fun onServiceAdded(status: Int, service: BluetoothGattService?) {
            handler.post {
                if (gattServer == null) return@post
                if (status == BluetoothGatt.GATT_SUCCESS) {
                    serviceReady = true
                    log("GATT サービスを公開しました")
                    startAdvertising()
                } else {
                    log("GATT サービスの公開に失敗しました ($status)")
                    closeServer()
                    scheduleServerRetry()
                }
            }
        }

        override fun onConnectionStateChange(device: BluetoothDevice, status: Int, newState: Int) {
            handler.post { handleServerConnectionChange(device, newState) }
        }

        override fun onMtuChanged(device: BluetoothDevice, mtu: Int) {
            handler.post {
                serverMtu[device.address] = mtu
                val link = serverLinks[device.address] ?: return@post
                link.mtu = mtu
                if (link.openPending) openServerLink(link)
            }
        }

        override fun onDescriptorWriteRequest(
            device: BluetoothDevice,
            requestId: Int,
            descriptor: BluetoothGattDescriptor,
            preparedWrite: Boolean,
            responseNeeded: Boolean,
            offset: Int,
            value: ByteArray?,
        ) {
            val copy = value?.copyOf()
            handler.post {
                handleCccdWrite(device, requestId, descriptor, preparedWrite, responseNeeded, offset, copy)
            }
        }

        override fun onDescriptorReadRequest(
            device: BluetoothDevice,
            requestId: Int,
            offset: Int,
            descriptor: BluetoothGattDescriptor,
        ) {
            handler.post {
                val server = gattServer ?: return@post
                if (descriptor.uuid == CCCD_UUID) {
                    val value = if (serverLinks.containsKey(device.address)) {
                        BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE
                    } else {
                        BluetoothGattDescriptor.DISABLE_NOTIFICATION_VALUE
                    }
                    server.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, 0, value)
                } else {
                    server.sendResponse(device, requestId, BluetoothGatt.GATT_READ_NOT_PERMITTED, 0, null)
                }
            }
        }

        override fun onCharacteristicWriteRequest(
            device: BluetoothDevice,
            requestId: Int,
            characteristic: BluetoothGattCharacteristic,
            preparedWrite: Boolean,
            responseNeeded: Boolean,
            offset: Int,
            value: ByteArray?,
        ) {
            val copy = value?.copyOf()
            handler.post {
                handleRxWrite(device, requestId, characteristic, preparedWrite, responseNeeded, offset, copy)
            }
        }

        override fun onCharacteristicReadRequest(
            device: BluetoothDevice,
            requestId: Int,
            offset: Int,
            characteristic: BluetoothGattCharacteristic,
        ) {
            handler.post {
                // TX は通知専用。読み取りには空を返す。
                gattServer?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, 0, ByteArray(0))
            }
        }

        override fun onExecuteWrite(device: BluetoothDevice, requestId: Int, execute: Boolean) {
            handler.post {
                gattServer?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, 0, null)
            }
        }

        override fun onNotificationSent(device: BluetoothDevice, status: Int) {
            handler.post {
                val link = serverLinks[device.address] ?: return@post
                completeSend(link, if (status == BluetoothGatt.GATT_SUCCESS) null else "notify_failed_$status")
            }
        }
    }

    private fun openServer() {
        val cfg = config ?: return
        if (gattServer != null) return
        val mgr = manager ?: return
        val server = try {
            mgr.openGattServer(appContext, serverCallback)
        } catch (e: RuntimeException) {
            Log.w(TAG, "openGattServer に失敗", e)
            null
        }
        if (server == null) {
            log("GATT サーバを開けません")
            scheduleServerRetry()
            return
        }
        gattServer = server
        serviceReady = false

        val rx = BluetoothGattCharacteristic(
            cfg.rxUuid,
            BluetoothGattCharacteristic.PROPERTY_WRITE_NO_RESPONSE or BluetoothGattCharacteristic.PROPERTY_WRITE,
            BluetoothGattCharacteristic.PERMISSION_WRITE,
        )
        val tx = BluetoothGattCharacteristic(
            cfg.txUuid,
            BluetoothGattCharacteristic.PROPERTY_NOTIFY,
            BluetoothGattCharacteristic.PERMISSION_READ,
        )
        tx.addDescriptor(
            BluetoothGattDescriptor(
                CCCD_UUID,
                BluetoothGattDescriptor.PERMISSION_READ or BluetoothGattDescriptor.PERMISSION_WRITE,
            ),
        )
        val service = BluetoothGattService(cfg.serviceUuid, BluetoothGattService.SERVICE_TYPE_PRIMARY)
        service.addCharacteristic(rx)
        service.addCharacteristic(tx)
        txCharacteristic = tx

        val added = try {
            server.addService(service)
        } catch (e: RuntimeException) {
            Log.w(TAG, "addService に失敗", e)
            false
        }
        if (!added) {
            log("GATT サービスの追加に失敗しました")
            closeServer()
            scheduleServerRetry()
        }
    }

    private fun scheduleServerRetry() {
        if (serverRetryPending) return
        serverRetryPending = true
        handler.postDelayed({
            serverRetryPending = false
            if (running && poweredOn && gattServer == null) openServer()
        }, SERVER_RETRY_MS)
    }

    private fun closeServer() {
        val server = gattServer ?: return
        gattServer = null
        txCharacteristic = null
        serviceReady = false
        serverMtu.clear()
        try {
            server.clearServices()
            server.close()
        } catch (e: RuntimeException) {
            Log.w(TAG, "GATT サーバの close に失敗", e)
        }
    }

    private fun handleServerConnectionChange(device: BluetoothDevice, newState: Int) {
        val address = device.address
        if (newState == BluetoothProfile.STATE_DISCONNECTED) {
            serverMtu.remove(address)
            serverLinks[address]?.let { finishLink(it, "disconnected") }
        }
    }

    /** central が TX の CCCD を書いた（通知の有効化 = リンク確立）。 */
    private fun handleCccdWrite(
        device: BluetoothDevice,
        requestId: Int,
        descriptor: BluetoothGattDescriptor,
        preparedWrite: Boolean,
        responseNeeded: Boolean,
        offset: Int,
        value: ByteArray?,
    ) {
        val server = gattServer ?: return
        val cfg = config
        val isTxCccd = descriptor.uuid == CCCD_UUID && descriptor.characteristic?.uuid == cfg?.txUuid
        if (!isTxCccd || value == null || preparedWrite) {
            if (responseNeeded) {
                server.sendResponse(device, requestId, BluetoothGatt.GATT_REQUEST_NOT_SUPPORTED, offset, value)
            }
            return
        }
        val address = device.address
        val enable = value.any { it.toInt() != 0 }
        if (!enable) {
            if (responseNeeded) server.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, offset, value)
            serverLinks[address]?.let { finishLink(it, "unsubscribed") }
            return
        }
        if (serverLinks.containsKey(address)) {
            if (responseNeeded) server.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, offset, value)
            return
        }
        if (serverLinks.size >= MAX_INCOMING) {
            log("受け入れ上限（$MAX_INCOMING 本）のため拒否: $address")
            if (responseNeeded) server.sendResponse(device, requestId, BluetoothGatt.GATT_FAILURE, offset, value)
            return
        }
        val knownMtu = serverMtu[address]
        val link = Link(nextLinkId++, address, initiator = false).apply {
            this.device = device
            mtu = knownMtu ?: DEFAULT_MTU
            connected = true
            opened = true
        }
        links[link.id] = link
        serverLinks[address] = link
        keepAwake(WAKE_LINK_MS)
        if (responseNeeded) server.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, offset, value)
        if (knownMtu != null) {
            openServerLink(link)
        } else {
            // MTU の知らせが購読より後に来る端末がある。少し待たないと、このリンクは
            // 20 バイトずつの送受信になり、1 回の同期で渡せる量が大きく減る。
            link.openPending = true
            val timeout = Runnable { if (link.openPending && !link.finished) openServerLink(link) }
            link.openTimeout = timeout
            handler.postDelayed(timeout, SERVER_MTU_WAIT_MS)
        }
    }

    /** peripheral 側のリンクを Dart に知らせ、待つ間に溜めた受信を流す。 */
    private fun openServerLink(link: Link) {
        if (link.finished) return
        link.openPending = false
        link.openTimeout?.let { handler.removeCallbacks(it) }
        link.openTimeout = null
        log("リンク確立 #${link.id} ${link.peerId}（peripheral, MTU ${link.mtu}）")
        emit(
            "linkOpened",
            "linkId" to link.id,
            "peerId" to link.peerId,
            "maxChunk" to maxChunkOf(link),
            "initiator" to false,
        )
        for (chunk in link.earlyData) {
            emit("data", "linkId" to link.id, "data" to chunk)
        }
        link.earlyData.clear()
    }

    /** central からの RX 書き込み（受信チャンク）。 */
    private fun handleRxWrite(
        device: BluetoothDevice,
        requestId: Int,
        characteristic: BluetoothGattCharacteristic,
        preparedWrite: Boolean,
        responseNeeded: Boolean,
        offset: Int,
        value: ByteArray?,
    ) {
        val server = gattServer ?: return
        val isRx = characteristic.uuid == config?.rxUuid
        if (!isRx || value == null || preparedWrite) {
            if (responseNeeded) {
                server.sendResponse(device, requestId, BluetoothGatt.GATT_REQUEST_NOT_SUPPORTED, offset, value)
            }
            return
        }
        if (responseNeeded) server.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, offset, value)
        val link = serverLinks[device.address]
        if (link == null) {
            Log.d(TAG, "購読前の書き込みを破棄: ${device.address}")
            return
        }
        keepAwake(WAKE_LINK_MS)
        if (link.openPending) {
            link.earlyData.add(value)
            return
        }
        emit("data", "linkId" to link.id, "data" to value)
    }

    private fun sendServer(link: Link, data: ByteArray) {
        if (link.finished || link.pendingSend == null) return
        val server = gattServer
        val tx = txCharacteristic
        val device = link.device
        if (server == null || tx == null || device == null) {
            completeSend(link, "not_connected")
            return
        }
        link.writeAttempts++
        val accepted: Boolean
        val retry: Boolean
        var code = 0
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            val rc = try {
                server.notifyCharacteristicChanged(device, tx, false, data)
            } catch (e: RuntimeException) {
                BluetoothStatusCodes.ERROR_UNKNOWN
            }
            code = rc
            accepted = rc == BluetoothStatusCodes.SUCCESS
            retry = isTransientWriteError(rc)
        } else {
            accepted = notifyLegacy(server, device, tx, data)
            retry = !accepted
        }
        when {
            accepted -> Unit // onNotificationSent で完了する
            retry && link.writeAttempts < MAX_WRITE_ATTEMPTS ->
                handler.postDelayed({ sendServer(link, data) }, WRITE_RETRY_DELAY_MS)
            else -> {
                log("通知を送れません #${link.id} rc=$code 試行 ${link.writeAttempts} 回")
                completeSend(link, "notify_rejected_$code")
            }
        }
    }

    @Suppress("DEPRECATION")
    private fun notifyLegacy(
        server: BluetoothGattServer,
        device: BluetoothDevice,
        tx: BluetoothGattCharacteristic,
        data: ByteArray,
    ): Boolean {
        tx.value = data
        return try {
            server.notifyCharacteristicChanged(device, tx, false)
        } catch (e: RuntimeException) {
            false
        }
    }

    // ================================================================ GATT クライアント（central 側）

    private val clientCallback = object : BluetoothGattCallback() {
        override fun onConnectionStateChange(gatt: BluetoothGatt, status: Int, newState: Int) {
            runOnEngine { handleClientConnectionChange(gatt, status, newState) }
        }

        override fun onMtuChanged(gatt: BluetoothGatt, mtu: Int, status: Int) {
            runOnEngine {
                val link = gattLinks[gatt] ?: return@runOnEngine
                if (link.finished) return@runOnEngine
                link.mtu = if (status == BluetoothGatt.GATT_SUCCESS) mtu else DEFAULT_MTU
                if (!link.discovering) startDiscovery(link, gatt)
            }
        }

        override fun onServicesDiscovered(gatt: BluetoothGatt, status: Int) {
            runOnEngine { handleServicesDiscovered(gatt, status) }
        }

        override fun onDescriptorWrite(gatt: BluetoothGatt, descriptor: BluetoothGattDescriptor, status: Int) {
            runOnEngine { handleClientCccdWritten(gatt, descriptor, status) }
        }

        override fun onCharacteristicWrite(
            gatt: BluetoothGatt,
            characteristic: BluetoothGattCharacteristic,
            status: Int,
        ) {
            runOnEngine { handleClientWriteResult(gatt, status) }
        }

        // API 33 以上で呼ばれる。
        override fun onCharacteristicChanged(
            gatt: BluetoothGatt,
            characteristic: BluetoothGattCharacteristic,
            value: ByteArray,
        ) {
            val copy = value.copyOf()
            runOnEngine { handleNotification(gatt, characteristic, copy) }
        }

        @Deprecated("API 33 未満向け。33 以上では value 付きの方が呼ばれる")
        override fun onCharacteristicChanged(gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) return
            val copy = legacyValue(characteristic) ?: return
            runOnEngine { handleNotification(gatt, characteristic, copy) }
        }
    }

    @Suppress("DEPRECATION")
    private fun legacyValue(characteristic: BluetoothGattCharacteristic): ByteArray? =
        characteristic.value?.copyOf()

    private fun runOnEngine(block: () -> Unit) {
        if (Looper.myLooper() == handler.looper) block() else handler.post(block)
    }

    private fun connectInternal(peerId: String) {
        val link = Link(nextLinkId++, peerId, initiator = true)
        if (!running || !poweredOn) {
            rejectConnect(link, "not_running")
            return
        }
        if (links.values.any { it.initiator && it.peerId == peerId }) {
            rejectConnect(link, "duplicate")
            return
        }
        if (links.values.count { it.initiator } >= MAX_OUTGOING) {
            rejectConnect(link, "busy")
            return
        }
        val device = knownDevices[peerId] ?: try {
            adapter?.getRemoteDevice(peerId)
        } catch (e: IllegalArgumentException) {
            null
        }
        if (device == null) {
            rejectConnect(link, "invalid_peer")
            return
        }
        link.device = device
        links[link.id] = link
        keepAwake(WAKE_LINK_MS)
        log("接続開始 #${link.id} $peerId")
        openGatt(link)
    }

    /** 接続を始める前に断る（linkClosed は必ず 1 回流す）。 */
    private fun rejectConnect(link: Link, reason: String) {
        link.finished = true
        Log.d(TAG, "接続要求を拒否 ${link.peerId}: $reason")
        emitLinkClosed(link, reason)
    }

    private fun openGatt(link: Link) {
        val device = link.device ?: return
        val gatt = try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                device.connectGatt(
                    appContext,
                    false,
                    clientCallback,
                    BluetoothDevice.TRANSPORT_LE,
                    BluetoothDevice.PHY_LE_1M_MASK,
                    // API 33 未満では、通知の値を共有の characteristic に書いてから handler へ
                    // 投げるため、続けて届いた通知で値が上書きされて取りこぼす。handler を渡さず
                    // Binder スレッドで受けてすぐ複製し、runOnEngine でエンジンのスレッドへ移す。
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) handler else null,
                )
            } else {
                // Android 7.x: PHY と handler は指定できない（Binder スレッドで受ける、上と同じ扱い）。
                device.connectGatt(appContext, false, clientCallback, BluetoothDevice.TRANSPORT_LE)
            }
        } catch (e: RuntimeException) {
            Log.w(TAG, "connectGatt に失敗", e)
            null
        }
        if (gatt == null) {
            finishLink(link, "connect_failed")
            return
        }
        link.gatt = gatt
        link.connected = false
        link.discovering = false
        gattLinks[gatt] = link
        armConnectTimeout(link)
    }

    private fun armConnectTimeout(link: Link) {
        link.connectTimeout?.let { handler.removeCallbacks(it) }
        val runnable = Runnable {
            if (!link.opened && !link.finished) {
                log("接続タイムアウト #${link.id} ${link.peerId}")
                finishLink(link, "timeout")
            }
        }
        link.connectTimeout = runnable
        handler.postDelayed(runnable, CONNECT_TIMEOUT_MS)
    }

    private fun handleClientConnectionChange(gatt: BluetoothGatt, status: Int, newState: Int) {
        val link = gattLinks[gatt]
        if (link == null) {
            // 管理外の GATT（close 済みの残骸）。確実に閉じる。
            try {
                gatt.disconnect()
            } catch (e: RuntimeException) {
                Log.w(TAG, "disconnect に失敗", e)
            }
            closeGattQuietly(gatt)
            return
        }
        if (newState == BluetoothProfile.STATE_CONNECTED && status == BluetoothGatt.GATT_SUCCESS) {
            if (link.finished) {
                // close() 済み。切断して DISCONNECTED で close する。
                try {
                    gatt.disconnect()
                } catch (e: RuntimeException) {
                    Log.w(TAG, "disconnect に失敗", e)
                }
                return
            }
            link.connected = true
            Log.d(TAG, "接続 #${link.id} → MTU 要求")
            val requested = try {
                gatt.requestMtu(REQUEST_MTU)
            } catch (e: RuntimeException) {
                false
            }
            if (!requested) {
                startDiscovery(link, gatt)
                return
            }
            val fallback = Runnable {
                if (!link.finished && !link.discovering) {
                    Log.d(TAG, "MTU 応答なし #${link.id}、既定値で続行")
                    startDiscovery(link, gatt)
                }
            }
            link.mtuFallback = fallback
            handler.postDelayed(fallback, MTU_TIMEOUT_MS)
            return
        }

        // 切断またはエラー。必ず close する。
        gattLinks.remove(gatt)
        closeGattQuietly(gatt)
        link.closeFallback?.let { handler.removeCallbacks(it) }
        link.closeFallback = null
        link.mtuFallback?.let { handler.removeCallbacks(it) }
        link.mtuFallback = null
        if (link.gatt === gatt) link.gatt = null
        link.connected = false
        if (link.finished) return

        if (status == GATT_STATUS_133 && !link.opened && !link.retried133) {
            link.retried133 = true
            link.connectTimeout?.let { handler.removeCallbacks(it) }
            link.connectTimeout = null
            log("status 133 #${link.id}、少し待って再試行します")
            handler.postDelayed({ if (!link.finished) openGatt(link) }, RETRY_133_DELAY_MS)
            return
        }
        finishLink(link, if (link.opened) "disconnected" else "connect_failed_$status")
    }

    private fun startDiscovery(link: Link, gatt: BluetoothGatt) {
        link.discovering = true
        link.mtuFallback?.let { handler.removeCallbacks(it) }
        link.mtuFallback = null
        val started = try {
            gatt.discoverServices()
        } catch (e: RuntimeException) {
            false
        }
        if (!started) finishLink(link, "discover_failed")
    }

    private fun handleServicesDiscovered(gatt: BluetoothGatt, status: Int) {
        val link = gattLinks[gatt] ?: return
        if (link.finished) return
        val cfg = config ?: return
        if (status != BluetoothGatt.GATT_SUCCESS) {
            finishLink(link, "discover_failed_$status")
            return
        }
        val service = gatt.getService(cfg.serviceUuid)
        val rx = service?.getCharacteristic(cfg.rxUuid)
        val tx = service?.getCharacteristic(cfg.txUuid)
        val cccd = tx?.getDescriptor(CCCD_UUID)
        if (rx == null || tx == null || cccd == null) {
            // Apple 製造者データ由来の候補など、回覧板ではない端末。
            Log.d(TAG, "サービスなし #${link.id} ${link.peerId}")
            finishLink(link, "no_service")
            return
        }
        link.rx = rx
        link.tx = tx
        if (!gatt.setCharacteristicNotification(tx, true)) {
            finishLink(link, "notify_failed")
            return
        }
        val accepted = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            gatt.writeDescriptor(cccd, BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE) ==
                BluetoothStatusCodes.SUCCESS
        } else {
            writeDescriptorLegacy(gatt, cccd, BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE)
        }
        if (!accepted) finishLink(link, "cccd_failed")
    }

    @Suppress("DEPRECATION")
    private fun writeDescriptorLegacy(
        gatt: BluetoothGatt,
        descriptor: BluetoothGattDescriptor,
        value: ByteArray,
    ): Boolean {
        descriptor.value = value
        return gatt.writeDescriptor(descriptor)
    }

    private fun handleClientCccdWritten(gatt: BluetoothGatt, descriptor: BluetoothGattDescriptor, status: Int) {
        val link = gattLinks[gatt] ?: return
        if (link.finished || link.opened || descriptor.uuid != CCCD_UUID) return
        if (status != BluetoothGatt.GATT_SUCCESS) {
            finishLink(link, "cccd_failed_$status")
            return
        }
        link.opened = true
        link.connectTimeout?.let { handler.removeCallbacks(it) }
        link.connectTimeout = null
        log("リンク確立 #${link.id} ${link.peerId}（central, MTU ${link.mtu}）")
        emit(
            "linkOpened",
            "linkId" to link.id,
            "peerId" to link.peerId,
            "maxChunk" to maxChunkOf(link),
            "initiator" to true,
        )
        for (chunk in link.earlyData) {
            emit("data", "linkId" to link.id, "data" to chunk)
        }
        link.earlyData.clear()
    }

    private fun handleNotification(gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic, value: ByteArray) {
        val link = gattLinks[gatt] ?: return
        if (link.finished) return
        if (characteristic.uuid != config?.txUuid) return
        keepAwake(WAKE_LINK_MS)
        if (!link.opened) {
            // 相手は購読を受けた直後に HELLO を送るので、こちらの購読完了
            // （onDescriptorWrite）より先に届くことがある。捨てずに溜めておく（#152）。
            if (link.earlyData.size < MAX_EARLY_CHUNKS) link.earlyData.add(value)
            return
        }
        emit("data", "linkId" to link.id, "data" to value)
    }

    private fun handleClientWriteResult(gatt: BluetoothGatt, status: Int) {
        // API 33+ では writeCharacteristic の戻り値で完了済み。
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) return
        val link = gattLinks[gatt] ?: return
        if (link.pendingSend == null) return
        completeSend(link, if (status == BluetoothGatt.GATT_SUCCESS) null else "write_failed_$status")
    }

    private fun sendClient(link: Link, data: ByteArray) {
        if (link.finished || link.pendingSend == null) return
        val gatt = link.gatt
        val rx = link.rx
        if (gatt == null || rx == null) {
            completeSend(link, "not_connected")
            return
        }
        link.writeAttempts++
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            val rc = try {
                gatt.writeCharacteristic(rx, data, BluetoothGattCharacteristic.WRITE_TYPE_NO_RESPONSE)
            } catch (e: RuntimeException) {
                BluetoothStatusCodes.ERROR_UNKNOWN
            }
            when {
                rc == BluetoothStatusCodes.SUCCESS -> completeSend(link, null) // スタックに渡った
                isTransientWriteError(rc) &&
                    link.writeAttempts < MAX_WRITE_ATTEMPTS ->
                    handler.postDelayed({ sendClient(link, data) }, WRITE_RETRY_DELAY_MS)
                else -> {
                    log("書き込めません #${link.id} rc=$rc 試行 ${link.writeAttempts} 回")
                    completeSend(link, "write_failed_$rc")
                }
            }
        } else {
            val accepted = writeCharacteristicLegacy(gatt, rx, data)
            if (accepted) return // onCharacteristicWrite で完了する
            if (link.writeAttempts < MAX_WRITE_ATTEMPTS) {
                handler.postDelayed({ sendClient(link, data) }, WRITE_RETRY_DELAY_MS)
            } else {
                completeSend(link, "write_failed")
            }
        }
    }

    /**
     * 待てば通る書き込みの失敗か（BUSY だけ）。ほかの失敗をやり直すと、実は送れて
     * いたチャンクを二重に送り、詰めて書いたフレームの列が壊れるおそれがある。
     */
    private fun isTransientWriteError(rc: Int): Boolean =
        rc == BluetoothStatusCodes.ERROR_GATT_WRITE_REQUEST_BUSY

    @Suppress("DEPRECATION")
    private fun writeCharacteristicLegacy(
        gatt: BluetoothGatt,
        characteristic: BluetoothGattCharacteristic,
        data: ByteArray,
    ): Boolean {
        characteristic.writeType = BluetoothGattCharacteristic.WRITE_TYPE_NO_RESPONSE
        characteristic.value = data
        return try {
            gatt.writeCharacteristic(characteristic)
        } catch (e: RuntimeException) {
            false
        }
    }

    // ================================================================ 送信・終了の共通処理

    /**
     * 1 回に書ける・通知できるバイト数。ATT の上限は MTU − 3 だが、Android の
     * GATT は属性値を 512 バイトまでしか扱わず、514 バイトの書き込みは
     * ERROR_UNKNOWN で失敗し続ける（エミュレータで 600 件の要約が 2 チャンクに
     * なったときに判明、#152）。
     */
    private fun maxChunkOf(link: Link): Int = minOf(link.mtu - 3, MAX_ATTR_LEN)

    private fun sendInternal(linkId: Int, data: ByteArray, callback: (String?) -> Unit) {
        val link = links[linkId]
        if (link == null || link.finished || !link.opened) {
            callback("not_connected")
            return
        }
        if (link.pendingSend != null) {
            // Dart 側は直列に await する前提。並行送信は拒否する。
            callback("busy")
            return
        }
        if (data.size > maxChunkOf(link)) {
            callback("too_large")
            return
        }
        link.pendingSend = callback
        link.writeAttempts = 0
        armSendTimeout(link)
        if (link.initiator) sendClient(link, data) else sendServer(link, data)
    }

    private fun armSendTimeout(link: Link) {
        link.sendTimeout?.let { handler.removeCallbacks(it) }
        val runnable = Runnable {
            if (link.pendingSend != null) {
                log("送信タイムアウト #${link.id}")
                completeSend(link, "send_timeout")
                finishLink(link, "send_timeout")
            }
        }
        link.sendTimeout = runnable
        handler.postDelayed(runnable, SEND_TIMEOUT_MS)
    }

    private fun completeSend(link: Link, error: String?) {
        link.sendTimeout?.let { handler.removeCallbacks(it) }
        link.sendTimeout = null
        val callback = link.pendingSend ?: return
        link.pendingSend = null
        callback(error)
    }

    private fun closeAllLinks(reason: String) {
        for (link in links.values.toList()) {
            finishLink(link, reason)
        }
    }

    /** リンクを終了する。linkClosed は必ず 1 回だけ流す。 */
    private fun finishLink(link: Link, reason: String) {
        if (link.finished) return
        link.finished = true
        link.connectTimeout?.let { handler.removeCallbacks(it) }
        link.connectTimeout = null
        link.mtuFallback?.let { handler.removeCallbacks(it) }
        link.mtuFallback = null
        link.openTimeout?.let { handler.removeCallbacks(it) }
        link.openTimeout = null
        link.openPending = false
        link.earlyData.clear()
        completeSend(link, "closed")
        links.remove(link.id)

        if (link.initiator) {
            val gatt = link.gatt
            if (gatt != null) {
                // 物理接続が残ると、相手（特に iPhone）は購読が続いているとみなし、次の同期の
                // 書き込みを捨てる。切る前に購読を解除する（届かなくても切断は続ける）。
                val unsubscribed = link.opened && link.connected && reason != "disconnected" &&
                    unsubscribeQuietly(gatt, link.tx)
                if (unsubscribed) {
                    handler.postDelayed({ disconnectGatt(link, gatt) }, UNSUBSCRIBE_DELAY_MS)
                } else {
                    disconnectGatt(link, gatt)
                }
            }
        } else {
            serverLinks.remove(link.peerId)
            if (reason != "disconnected" && reason != "unsubscribed") {
                val device = link.device
                if (device != null) {
                    try {
                        gattServer?.cancelConnection(device)
                    } catch (e: RuntimeException) {
                        Log.w(TAG, "cancelConnection に失敗", e)
                    }
                }
            }
        }
        log("リンク終了 #${link.id} ${link.peerId} ($reason)")
        emitLinkClosed(link, reason)
    }

    private fun disconnectGatt(link: Link, gatt: BluetoothGatt) {
        try {
            gatt.disconnect()
        } catch (e: RuntimeException) {
            Log.w(TAG, "disconnect に失敗", e)
        }
        if (link.connected) {
            // DISCONNECTED コールバックで close する。来なければ時間切れで close。
            val fallback = Runnable {
                if (gattLinks.remove(gatt) != null) closeGattQuietly(gatt)
                if (link.gatt === gatt) link.gatt = null
            }
            link.closeFallback = fallback
            handler.postDelayed(fallback, CLOSE_FALLBACK_MS)
        } else {
            gattLinks.remove(gatt)
            closeGattQuietly(gatt)
            link.gatt = null
        }
    }

    /** TX の通知を止める（CCCD に 0 を書く）。書き込みを受け付けたら true。 */
    private fun unsubscribeQuietly(gatt: BluetoothGatt, tx: BluetoothGattCharacteristic?): Boolean {
        if (tx == null) return false
        val cccd = tx.getDescriptor(CCCD_UUID) ?: return false
        return try {
            gatt.setCharacteristicNotification(tx, false)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                gatt.writeDescriptor(cccd, BluetoothGattDescriptor.DISABLE_NOTIFICATION_VALUE) ==
                    BluetoothStatusCodes.SUCCESS
            } else {
                writeDescriptorLegacy(gatt, cccd, BluetoothGattDescriptor.DISABLE_NOTIFICATION_VALUE)
            }
        } catch (e: RuntimeException) {
            false
        }
    }

    /** 期限付きでウェイクロックを取り直す（期限が来たら自動で放す）。 */
    private fun keepAwake(ms: Long) {
        val lock = wakeLock ?: return
        try {
            lock.acquire(ms)
        } catch (e: RuntimeException) {
            Log.w(TAG, "ウェイクロックを取れません", e)
        }
    }

    private fun releaseWake() {
        val lock = wakeLock ?: return
        try {
            if (lock.isHeld) lock.release()
        } catch (e: RuntimeException) {
            Log.w(TAG, "ウェイクロックを放せません", e)
        }
    }

    private fun closeGattQuietly(gatt: BluetoothGatt) {
        try {
            gatt.close()
        } catch (e: RuntimeException) {
            Log.w(TAG, "gatt.close に失敗", e)
        }
    }

    // ================================================================ イベント

    private fun emitLinkClosed(link: Link, reason: String) {
        emit("linkClosed", "linkId" to link.id, "peerId" to link.peerId, "reason" to reason)
    }

    private fun publishState(force: Boolean = false) {
        val state = Triple(poweredOn, scanning, advertising)
        if (!force && state == lastState) return
        lastState = state
        emit("state", "poweredOn" to poweredOn, "scanning" to scanning, "advertising" to advertising)
    }

    private fun emit(type: String, vararg fields: Pair<String, Any?>) {
        val map = HashMap<String, Any?>(fields.size + 1)
        map["type"] = type
        for ((key, value) in fields) map[key] = value
        listener.onEngineEvent(map)
    }

    private fun scanErrorName(code: Int): String = when (code) {
        ScanCallback.SCAN_FAILED_ALREADY_STARTED -> "already_started"
        ScanCallback.SCAN_FAILED_APPLICATION_REGISTRATION_FAILED -> "registration_failed"
        ScanCallback.SCAN_FAILED_FEATURE_UNSUPPORTED -> "unsupported"
        ScanCallback.SCAN_FAILED_INTERNAL_ERROR -> "internal_error"
        SCAN_FAILED_OUT_OF_HARDWARE_RESOURCES -> "out_of_hardware_resources"
        SCAN_FAILED_TOO_FREQUENTLY -> "too_frequently"
        else -> "code_$code"
    }

    private fun advertiseErrorName(code: Int): String = when (code) {
        AdvertiseCallback.ADVERTISE_FAILED_DATA_TOO_LARGE -> "data_too_large"
        AdvertiseCallback.ADVERTISE_FAILED_TOO_MANY_ADVERTISERS -> "too_many_advertisers"
        AdvertiseCallback.ADVERTISE_FAILED_ALREADY_STARTED -> "already_started"
        AdvertiseCallback.ADVERTISE_FAILED_INTERNAL_ERROR -> "internal_error"
        AdvertiseCallback.ADVERTISE_FAILED_FEATURE_UNSUPPORTED -> "unsupported"
        else -> "code_$code"
    }

    companion object {
        private const val TAG = "BleEngine"
        private val CCCD_UUID: UUID = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")
        private const val APPLE_COMPANY_ID = 0x004C
        private const val APPLE_OVERFLOW_TYPE: Byte = 0x01
        private const val DEFAULT_MTU = 23
        private const val REQUEST_MTU = 517
        // Dart 側の上限（通常 2、中継役 3）より大きくして、Dart の判断を native が断らないようにする。
        private const val MAX_OUTGOING = 4
        private const val MAX_INCOMING = 4
        private const val CONNECT_TIMEOUT_MS = 10_000L
        private const val MTU_TIMEOUT_MS = 2_000L
        private const val SEND_TIMEOUT_MS = 5_000L
        private const val CLOSE_FALLBACK_MS = 2_000L
        private const val SERVER_MTU_WAIT_MS = 500L
        private const val UNSUBSCRIBE_DELAY_MS = 150L
        private const val WAKE_DISCOVERY_MS = 10_000L
        private const val WAKE_LINK_MS = 60_000L
        private const val RETRY_133_DELAY_MS = 500L
        private const val WRITE_RETRY_DELAY_MS = 8L
        private const val MAX_WRITE_ATTEMPTS = 600
        private const val MAX_ATTR_LEN = 512
        private const val MAX_EARLY_CHUNKS = 64
        private const val SCAN_RESTART_MS = 9 * 60_000L
        private const val SCAN_QUOTA_WINDOW_MS = 30_000L
        private const val SCAN_QUOTA_COUNT = 5
        private const val SCAN_RETRY_MS = 30_000L
        private const val ADVERTISE_RETRY_MS = 30_000L
        private const val SERVER_RETRY_MS = 5_000L
        private const val DISCOVER_DEDUP_MS = 2_000L
        private const val DEVICE_CACHE_TTL_MS = 5 * 60_000L
        private const val CACHE_PRUNE_THRESHOLD = 256
        private const val GATT_STATUS_133 = 133
        private const val SCAN_FAILED_OUT_OF_HARDWARE_RESOURCES = 5
        private const val SCAN_FAILED_TOO_FREQUENTLY = 6
    }
}
