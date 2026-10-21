package jp.kairanban.kairanban

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.util.Log

/**
 * すれ違い通信を画面を閉じても続けるための connectedDevice 型 Foreground Service。
 *
 * BLE の実体は [jp.kairanban.kairanban.ble.BleEngine] が持つ。このサービスは
 * 「アプリが前景相当で動いている」状態を OS に示すためだけに存在する。
 */
class MeshService : Service() {

    override fun onCreate() {
        super.onCreate()
        isRunning = true
        createChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // 起動猶予（5〜10 秒）内に必ず startForeground を呼ぶ。
        if (!goForeground()) {
            stopSelf()
            return START_NOT_STICKY
        }
        // 再起動後などエンジンが無い経路でも Dart を立ち上げる。
        (application as? KairanApplication)?.ensureEngine()
        return START_STICKY
    }

    override fun onDestroy() {
        isRunning = false
        stopForeground(STOP_FOREGROUND_REMOVE)
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun goForeground(): Boolean {
        val notification = buildNotification()
        return try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                startForeground(
                    NOTIFICATION_ID,
                    notification,
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE,
                )
            } else {
                startForeground(NOTIFICATION_ID, notification)
            }
            true
        } catch (e: SecurityException) {
            // API 34+: Bluetooth 権限が無いと connectedDevice 型は開始できない。
            Log.w(TAG, "startForeground に失敗（権限不足）", e)
            false
        } catch (e: IllegalStateException) {
            // ForegroundServiceStartNotAllowedException など（背景からの開始制限）。
            Log.w(TAG, "startForeground に失敗（開始制限）", e)
            false
        }
    }

    private fun createChannel() {
        val manager = getSystemService(NotificationManager::class.java) ?: return
        val channel = NotificationChannel(
            CHANNEL_ID,
            getString(R.string.mesh_channel_name),
            NotificationManager.IMPORTANCE_LOW,
        ).apply {
            description = getString(R.string.mesh_channel_description)
            setShowBadge(false)
        }
        manager.createNotificationChannel(channel)
    }

    private fun buildNotification(): Notification {
        val openApp = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val builder = Notification.Builder(this, CHANNEL_ID)
            .setContentTitle(getString(R.string.mesh_notification_title))
            .setContentText(getString(R.string.mesh_notification_text))
            .setSmallIcon(R.drawable.ic_stat_kairanban)
            .setContentIntent(openApp)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setCategory(Notification.CATEGORY_SERVICE)
            .setVisibility(Notification.VISIBILITY_PUBLIC)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            builder.setForegroundServiceBehavior(Notification.FOREGROUND_SERVICE_IMMEDIATE)
        }
        return builder.build()
    }

    companion object {
        private const val TAG = "MeshService"
        private const val CHANNEL_ID = "mesh"
        private const val NOTIFICATION_ID = 1

        /** サービスが生きているか（onCreate〜onDestroy）。 */
        @Volatile
        var isRunning: Boolean = false
            private set

        /** 前景サービスとして開始する。既に動いていれば通知を更新するだけ。 */
        fun start(context: Context) {
            context.startForegroundService(Intent(context, MeshService::class.java))
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, MeshService::class.java))
        }
    }
}
