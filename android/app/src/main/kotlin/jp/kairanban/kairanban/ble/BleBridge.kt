package jp.kairanban.kairanban.ble

import android.Manifest
import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.BatteryManager
import android.os.Looper
import android.os.PowerManager
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import android.provider.Settings
import android.speech.tts.TextToSpeech
import android.util.Log
import android.view.WindowManager
import android.content.IntentFilter
import android.media.AudioManager
import android.media.ToneGenerator
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import jp.kairanban.kairanban.MeshService
import jp.kairanban.kairanban.NoticeNotifier
import jp.kairanban.kairanban.ReminderReceiver
import java.util.Locale
import java.util.UUID

/**
 * Dart ↔ ネイティブの契約（docs/03_architecture.md §3）を実装する。
 *
 * - MethodChannel `jp.kairanban/ble`
 * - EventChannel `jp.kairanban/ble/events`
 *
 * 全ての Dart 向け呼び出しはメインスレッドで行う。EventChannel の購読が始まる前の
 * イベントはバッファし、購読開始時にまとめて流す。
 */
class BleBridge(private val appContext: Context) :
    FlutterPlugin, ActivityAware, BleEngine.Listener {

    private val main = Handler(Looper.getMainLooper())
    private val engine = BleEngine(appContext, this)
    private val prefs = appContext.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

    private var methodChannel: MethodChannel? = null
    private var eventChannel: EventChannel? = null
    private var sink: EventChannel.EventSink? = null
    private val buffered = ArrayDeque<Map<String, Any?>>()

    private var activity: Activity? = null

    /** 画面を消さない設定（中継役・「30 分 画面を 点けたままにする」）。Activity が付いたら適用する。 */
    private var keepScreenOn = false

    /** 読み上げ。初回の speak で生成する（初期化は非同期）。 */
    private var tts: TextToSpeech? = null
    private var ttsReady = false
    private var pendingSpeech: Pair<String, Double>? = null
    private val pendingPermissionResults = mutableListOf<MethodChannel.Result>()
    private val pendingNotificationResults = mutableListOf<MethodChannel.Result>()
    private var pendingBatteryResult: MethodChannel.Result? = null

    // ---------------------------------------------------------------- FlutterPlugin

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methodChannel = MethodChannel(binding.binaryMessenger, METHOD_CHANNEL).also {
            it.setMethodCallHandler(::onMethodCall)
        }
        eventChannel = EventChannel(binding.binaryMessenger, EVENT_CHANNEL).also {
            it.setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
                    sink = events
                    while (buffered.isNotEmpty()) {
                        events.success(buffered.removeFirst())
                    }
                    // 購読直後に現在状態を 1 回流す。
                    events.success(withPermission(engine.currentStateEvent()))
                }

                override fun onCancel(arguments: Any?) {
                    sink = null
                }
            })
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methodChannel?.setMethodCallHandler(null)
        methodChannel = null
        eventChannel?.setStreamHandler(null)
        eventChannel = null
        sink = null
    }

    // ---------------------------------------------------------------- ActivityAware

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
        applyKeepScreenOn()
    }

    override fun onDetachedFromActivityForConfigChanges() {
        activity = null
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        activity = binding.activity
        applyKeepScreenOn()
    }

    override fun onDetachedFromActivity() {
        activity = null
        // 画面が閉じられると結果は届かないので、待っている要求を失敗で解決する。
        resolvePermissionRequests(false)
        resolveNotificationRequests(false)
        pendingBatteryResult?.success(false)
        pendingBatteryResult = null
    }

    // ---------------------------------------------------------------- Activity からの通知

    /** MainActivity.onResume から。前景にいる間に前景サービスの取りこぼしを直す。 */
    fun onActivityResumed() {
        if (engine.running && !MeshService.isRunning && hasBlePermissions()) {
            startMeshService()
        }
    }

    /** MainActivity.onRequestPermissionsResult から。処理したら true。 */
    fun onRequestPermissionsResult(
        requestCode: Int,
        @Suppress("UNUSED_PARAMETER") permissions: Array<out String>,
        @Suppress("UNUSED_PARAMETER") grantResults: IntArray,
    ): Boolean {
        when (requestCode) {
            REQUEST_PERMISSIONS -> {
                resolvePermissionRequests(hasBlePermissions())
                emit(withPermission(engine.currentStateEvent()))
                return true
            }
            REQUEST_NOTIFICATION -> {
                resolveNotificationRequests(NoticeNotifier.hasPermission(appContext))
                return true
            }
        }
        return false
    }

    /** MainActivity.onActivityResult から。処理したら true。 */
    fun onActivityResult(
        requestCode: Int,
        @Suppress("UNUSED_PARAMETER") resultCode: Int,
        @Suppress("UNUSED_PARAMETER") data: Intent?,
    ): Boolean {
        if (requestCode != REQUEST_BATTERY) return false
        pendingBatteryResult?.success(isIgnoringBatteryOptimizations())
        pendingBatteryResult = null
        return true
    }

    // ---------------------------------------------------------------- MethodChannel

    private fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "getState" -> result.success(
                    mapOf(
                        "supported" to engine.isSupported,
                        "poweredOn" to engine.poweredOn,
                        "permission" to permissionState(),
                        "running" to engine.running,
                    ),
                )
                "requestPermissions" -> requestPermissions(result)
                "start" -> start(call, result)
                "stop" -> {
                    engine.stop()
                    MeshService.stop(appContext)
                    result.success(null)
                }
                "setLowPower" -> {
                    engine.setLowPower(call.argument<Boolean>("lowPower") ?: false)
                    result.success(null)
                }
                "connect" -> {
                    val peerId = call.argument<String>("peerId")
                    if (peerId.isNullOrEmpty()) {
                        result.error("bad_args", "peerId がありません", null)
                        return
                    }
                    engine.connect(peerId)
                    result.success(null)
                }
                "send" -> {
                    val linkId = call.argument<Number>("linkId")?.toInt()
                    val data = call.argument<ByteArray>("data")
                    if (linkId == null || data == null) {
                        result.error("bad_args", "linkId / data がありません", null)
                        return
                    }
                    engine.send(linkId, data) { error ->
                        main.post {
                            if (error == null) {
                                result.success(null)
                            } else {
                                result.error("send_failed", error, null)
                            }
                        }
                    }
                }
                "close" -> {
                    val linkId = call.argument<Number>("linkId")?.toInt()
                    if (linkId == null) {
                        result.error("bad_args", "linkId がありません", null)
                        return
                    }
                    engine.close(linkId)
                    result.success(null)
                }
                "requestBatteryOptimizationExemption" -> requestBatteryExemption(result)
                "openAppSettings" -> {
                    openAppSettings()
                    result.success(null)
                }
                "requestNotificationPermission" -> requestNotificationPermission(result)
                "showNotice" -> {
                    val id = call.argument<Number>("id")?.toInt()
                    val title = call.argument<String>("title")
                    val body = call.argument<String>("body") ?: ""
                    val groupCode = call.argument<Number>("groupCode")?.toInt() ?: 0
                    val importance = call.argument<String>("importance") ?: "important"
                    val msgId = call.argument<Number>("msgId")?.toLong()
                    if (id == null || title == null) {
                        result.error("bad_args", "id / title がありません", null)
                        return
                    }
                    NoticeNotifier.show(appContext, id, title, body, groupCode, importance, msgId)
                    result.success(null)
                }
                "cancelNotice" -> {
                    call.argument<Number>("id")?.toInt()?.let { NoticeNotifier.cancel(appContext, it) }
                    result.success(null)
                }
                "setKeepScreenOn" -> {
                    keepScreenOn = call.argument<Boolean>("on") ?: false
                    applyKeepScreenOn()
                    result.success(null)
                }
                "playChime" -> {
                    playChime()
                    result.success(null)
                }
                "getBattery" -> result.success(battery())
                "speak" -> {
                    speak(call.argument<String>("text") ?: "", call.argument<Double>("rate") ?: 0.8)
                    result.success(null)
                }
                "stopSpeaking" -> {
                    tts?.stop()
                    pendingSpeech = null
                    result.success(null)
                }
                "scheduleReminder" -> {
                    val at = call.argument<Number>("at")?.toLong()
                    val title = call.argument<String>("title") ?: ""
                    val body = call.argument<String>("body") ?: ""
                    if (at != null) {
                        ReminderReceiver.schedule(appContext, title, body, at)
                    }
                    result.success(null)
                }
                "cancelReminder" -> {
                    ReminderReceiver.cancel(appContext)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        } catch (e: RuntimeException) {
            Log.w(TAG, "${call.method} の処理に失敗", e)
            result.error("internal", e.message, null)
        }
    }

    private fun start(call: MethodCall, result: MethodChannel.Result) {
        val serviceUuid = call.argument<String>("serviceUuid")
        val rxUuid = call.argument<String>("rxUuid")
        val txUuid = call.argument<String>("txUuid")
        val nodeId = call.argument<ByteArray>("nodeId")
        val lowPower = call.argument<Boolean>("lowPower") ?: false
        if (serviceUuid == null || rxUuid == null || txUuid == null || nodeId == null) {
            result.error("bad_args", "serviceUuid / rxUuid / txUuid / nodeId が必要です", null)
            return
        }
        val config = try {
            BleEngine.Config(
                serviceUuid = UUID.fromString(serviceUuid),
                rxUuid = UUID.fromString(rxUuid),
                txUuid = UUID.fromString(txUuid),
                nodeId = nodeId,
                lowPower = lowPower,
            )
        } catch (e: IllegalArgumentException) {
            result.error("bad_args", "UUID の形式が不正です: ${e.message}", null)
            return
        }
        if (!engine.isSupported) {
            engine.log("この端末は Bluetooth LE に対応していません")
            emit(withPermission(engine.currentStateEvent()))
            result.success(null)
            return
        }
        if (!hasBlePermissions()) {
            // 権限が無いと前景サービスも BLE も開始できない。状態だけ知らせて正常終了する。
            engine.log("Bluetooth の権限がないため開始できません")
            emit(withPermission(engine.currentStateEvent()))
            result.success(null)
            return
        }
        startMeshService()
        engine.start(config)
        result.success(null)
    }

    private fun startMeshService() {
        try {
            MeshService.start(appContext)
        } catch (e: RuntimeException) {
            // 背景からの前景サービス開始制限など。BLE 自体は動かす。
            Log.w(TAG, "MeshService を開始できません", e)
            engine.log("常駐サービスを開始できません: ${e.message}")
        }
    }

    // ---------------------------------------------------------------- 権限

    private fun blePermissions(): Array<String> =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            arrayOf(
                Manifest.permission.BLUETOOTH_SCAN,
                Manifest.permission.BLUETOOTH_ADVERTISE,
                Manifest.permission.BLUETOOTH_CONNECT,
            )
        } else {
            arrayOf(Manifest.permission.ACCESS_FINE_LOCATION)
        }

    /** 要求する権限。BLE 権限に加えて通知権限（API 33+、結果判定には使わない）。 */
    private fun requestablePermissions(): Array<String> =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            blePermissions() + Manifest.permission.POST_NOTIFICATIONS
        } else {
            blePermissions()
        }

    private fun isGranted(permission: String): Boolean =
        appContext.checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED

    private fun hasBlePermissions(): Boolean = blePermissions().all(::isGranted)

    private fun permissionState(): String = when {
        hasBlePermissions() -> "granted"
        prefs.getBoolean(KEY_PERMISSION_ASKED, false) -> "denied"
        else -> "unknown"
    }

    private fun requestPermissions(result: MethodChannel.Result) {
        if (hasBlePermissions()) {
            result.success(true)
            return
        }
        val act = activity
        if (act == null) {
            // 画面が無いと要求ダイアログを出せない。
            result.success(false)
            return
        }
        val missing = requestablePermissions().filterNot(::isGranted).toTypedArray()
        prefs.edit().putBoolean(KEY_PERMISSION_ASKED, true).apply()
        val alreadyRequesting = pendingPermissionResults.isNotEmpty()
        pendingPermissionResults.add(result)
        if (!alreadyRequesting) {
            act.requestPermissions(missing, REQUEST_PERMISSIONS)
        }
    }

    private fun resolvePermissionRequests(granted: Boolean) {
        if (pendingPermissionResults.isEmpty()) return
        val results = pendingPermissionResults.toList()
        pendingPermissionResults.clear()
        results.forEach { it.success(granted) }
    }

    // ---------------------------------------------------------------- 通知権限

    /**
     * 通知権限（API 33+ の POST_NOTIFICATIONS）を要求する。
     * 既に許可済み・API 32 以下なら即 true。画面が無いときは false。
     */
    private fun requestNotificationPermission(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
            result.success(NoticeNotifier.canNotify(appContext))
            return
        }
        if (NoticeNotifier.hasPermission(appContext)) {
            NoticeNotifier.ensureChannel(appContext)
            result.success(true)
            return
        }
        val act = activity
        if (act == null) {
            result.success(false)
            return
        }
        val alreadyRequesting = pendingNotificationResults.isNotEmpty()
        pendingNotificationResults.add(result)
        if (!alreadyRequesting) {
            act.requestPermissions(
                arrayOf(Manifest.permission.POST_NOTIFICATIONS),
                REQUEST_NOTIFICATION,
            )
        }
    }

    private fun resolveNotificationRequests(granted: Boolean) {
        if (pendingNotificationResults.isEmpty()) return
        if (granted) {
            NoticeNotifier.ensureChannel(appContext)
        }
        val results = pendingNotificationResults.toList()
        pendingNotificationResults.clear()
        results.forEach { it.success(granted) }
    }

    // ---------------------------------------------------------------- 端末操作（C04 C06 C19）

    /** 画面を消さない設定を Activity のウィンドウに反映する（画面が無ければ次に付いたとき）。 */
    private fun applyKeepScreenOn() {
        val window = activity?.window ?: return
        if (keepScreenOn) {
            window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        } else {
            window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        }
    }

    /** 交換完了の短い音と振動。 */
    private fun playChime() {
        try {
            val tone = ToneGenerator(AudioManager.STREAM_NOTIFICATION, 80)
            tone.startTone(ToneGenerator.TONE_PROP_BEEP2, 200)
            main.postDelayed({ tone.release() }, 400)
        } catch (e: RuntimeException) {
            Log.w(TAG, "音を鳴らせません", e)
        }
        val vibrator: Vibrator? = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            appContext.getSystemService(VibratorManager::class.java)?.defaultVibrator
        } else {
            @Suppress("DEPRECATION")
            appContext.getSystemService(Vibrator::class.java)
        }
        try {
            vibrator?.vibrate(VibrationEffect.createOneShot(150, VibrationEffect.DEFAULT_AMPLITUDE))
        } catch (e: RuntimeException) {
            Log.w(TAG, "振動できません", e)
        }
    }

    /** 電池残量（0..100）と充電中か。取れなければ null。 */
    private fun battery(): Map<String, Any>? {
        val status = appContext.registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
            ?: return null
        val level = status.getIntExtra(BatteryManager.EXTRA_LEVEL, -1)
        val scale = status.getIntExtra(BatteryManager.EXTRA_SCALE, -1)
        if (level < 0 || scale <= 0) return null
        val state = status.getIntExtra(BatteryManager.EXTRA_STATUS, -1)
        val charging = state == BatteryManager.BATTERY_STATUS_CHARGING ||
            state == BatteryManager.BATTERY_STATUS_FULL
        return mapOf("level" to (level * 100 / scale), "charging" to charging)
    }

    /** OS 標準の音声合成（ja-JP）で読み上げる。[rate] は既定の速さに対する倍率。 */
    private fun speak(text: String, rate: Double) {
        if (text.isEmpty()) return
        val engine = tts
        if (engine == null) {
            pendingSpeech = text to rate
            tts = TextToSpeech(appContext) { status ->
                main.post {
                    ttsReady = status == TextToSpeech.SUCCESS
                    if (!ttsReady) {
                        Log.w(TAG, "読み上げを使えません（status=$status）")
                        pendingSpeech = null
                        return@post
                    }
                    val available = tts?.isLanguageAvailable(Locale.JAPAN) ?: TextToSpeech.LANG_NOT_SUPPORTED
                    if (available < TextToSpeech.LANG_AVAILABLE) {
                        engineLog("スマホに 日本語の 音声が 入っていません")
                    } else {
                        tts?.language = Locale.JAPAN
                    }
                    pendingSpeech?.let { (t, r) -> speakNow(t, r) }
                    pendingSpeech = null
                }
            }
            return
        }
        if (!ttsReady) {
            pendingSpeech = text to rate
            return
        }
        speakNow(text, rate)
    }

    private fun speakNow(text: String, rate: Double) {
        val engine = tts ?: return
        engine.setSpeechRate(rate.toFloat())
        engine.speak(text, TextToSpeech.QUEUE_FLUSH, null, "kairanban-speech")
    }

    private fun engineLog(message: String) {
        engine.log(message)
    }

    // ---------------------------------------------------------------- 電池最適化・設定画面

    private fun isIgnoringBatteryOptimizations(): Boolean {
        val pm = appContext.getSystemService(PowerManager::class.java) ?: return false
        return pm.isIgnoringBatteryOptimizations(appContext.packageName)
    }

    private fun requestBatteryExemption(result: MethodChannel.Result) {
        if (isIgnoringBatteryOptimizations()) {
            result.success(true)
            return
        }
        val act = activity
        if (act == null) {
            result.success(false)
            return
        }
        val intent = Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS)
            .setData(Uri.parse("package:${appContext.packageName}"))
        pendingBatteryResult?.success(false)
        pendingBatteryResult = result
        try {
            act.startActivityForResult(intent, REQUEST_BATTERY)
        } catch (e: ActivityNotFoundException) {
            pendingBatteryResult = null
            result.success(false)
        }
    }

    private fun openAppSettings() {
        val intent = Intent(
            Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
            Uri.fromParts("package", appContext.packageName, null),
        )
        val act = activity
        try {
            if (act != null) {
                act.startActivity(intent)
            } else {
                intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                appContext.startActivity(intent)
            }
        } catch (e: ActivityNotFoundException) {
            Log.w(TAG, "設定画面を開けません", e)
        }
    }

    // ---------------------------------------------------------------- イベント

    /** エンジンスレッドから呼ばれる。メインスレッドへ移して Dart に流す。 */
    override fun onEngineEvent(event: Map<String, Any?>) {
        main.post { emit(withPermission(event)) }
    }

    /** `state` イベントに permission を補う。 */
    private fun withPermission(event: Map<String, Any?>): Map<String, Any?> {
        if (event["type"] != "state") return event
        return HashMap(event).also { it["permission"] = permissionState() }
    }

    /** メインスレッドで呼ぶこと。 */
    private fun emit(event: Map<String, Any?>) {
        val s = sink
        if (s != null) {
            s.success(event)
            return
        }
        if (buffered.size >= MAX_BUFFERED_EVENTS) {
            buffered.removeFirst()
        }
        buffered.addLast(event)
    }

    companion object {
        private const val TAG = "BleBridge"
        private const val METHOD_CHANNEL = "jp.kairanban/ble"
        private const val EVENT_CHANNEL = "jp.kairanban/ble/events"
        private const val PREFS_NAME = "kairanban_native"
        private const val KEY_PERMISSION_ASKED = "permission_asked"
        private const val REQUEST_PERMISSIONS = 0x4B01
        private const val REQUEST_BATTERY = 0x4B02
        private const val REQUEST_NOTIFICATION = 0x4B03
        private const val MAX_BUFFERED_EVENTS = 2000
    }
}
