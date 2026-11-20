package jp.kairanban.kairanban

import android.Manifest
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Color
import android.os.Build
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import java.util.Calendar

/**
 * 「新しい お知らせ」の OS 通知（Dart の `showNotice` / `cancelNotice`）と、
 * 月 1 回の確認通知（`scheduleReminder`）。
 *
 * - 重要度（docs/08 C05）ごとにチャネルを分ける:
 *   urgent → `alerts`（IMPORTANCE_HIGH、振動 0.5 秒×3、赤いライト。公式の避難情報・注意喚起）、
 *   important → `notices`（IMPORTANCE_HIGH。午後 10 時〜午前 6 時は `notices_quiet`（LOW）で音を出さない）、
 *   normal → `notices_low`（IMPORTANCE_LOW）。常駐サービスのチャネル `mesh` とは分ける。
 * - 通知 ID は Dart が渡す msg_id の下位 31 ビット。同じ ID は置き換える（「N 件」への更新）。
 * - タップで [MainActivity] を開く。
 * - 通知権限（API 33+）が無ければ何もしない（権限要求は BleBridge が行う）。
 */
object NoticeNotifier {
    private const val TAG = "NoticeNotifier"
    const val CHANNEL_ID = "notices"
    const val CHANNEL_ALERTS = "alerts"
    const val CHANNEL_QUIET = "notices_quiet"
    const val CHANNEL_LOW = "notices_low"
    const val CHANNEL_REMINDER = "reminder"

    /** 確認通知の通知 ID（msg_id 由来の ID と重ならない値）。 */
    const val REMINDER_NOTIFICATION_ID = 2

    /** タップで開く Intent に付ける参加コード（将来、該当グループを開くために使う）。 */
    const val EXTRA_GROUP_CODE = "jp.kairanban.groupCode"

    /** タップで開く Intent に付ける msg_id（詳細を直接開くために使う）。 */
    const val EXTRA_MSG_ID = "jp.kairanban.msgId"

    /** API 33 以上で通知を出すのに必要な権限が揃っているか。それ未満は常に true。 */
    fun hasPermission(context: Context): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU ||
            context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) ==
            PackageManager.PERMISSION_GRANTED

    /** 通知を出せる状態か（権限があり、アプリの通知が OS 設定でオフにされていない）。 */
    fun canNotify(context: Context): Boolean =
        hasPermission(context) && NotificationManagerCompat.from(context).areNotificationsEnabled()

    fun ensureChannel(context: Context) {
        // 通知チャネルは Android 8.0 から。7.x は show() の優先度と音・振動の指定で扱う。
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = context.getSystemService(NotificationManager::class.java) ?: return
        if (manager.getNotificationChannel(CHANNEL_ID) == null) {
            manager.createNotificationChannel(
                NotificationChannel(
                    CHANNEL_ID,
                    context.getString(R.string.notices_channel_name),
                    NotificationManager.IMPORTANCE_HIGH,
                ).apply {
                    description = context.getString(R.string.notices_channel_description)
                    setShowBadge(true)
                    enableVibration(true)
                },
            )
        }
        if (manager.getNotificationChannel(CHANNEL_ALERTS) == null) {
            manager.createNotificationChannel(
                NotificationChannel(
                    CHANNEL_ALERTS,
                    context.getString(R.string.alerts_channel_name),
                    NotificationManager.IMPORTANCE_HIGH,
                ).apply {
                    description = context.getString(R.string.alerts_channel_description)
                    setShowBadge(true)
                    enableVibration(true)
                    vibrationPattern = longArrayOf(0, 500, 300, 500, 300, 500)
                    enableLights(true)
                    lightColor = Color.RED
                    setBypassDnd(false)
                },
            )
        }
        if (manager.getNotificationChannel(CHANNEL_QUIET) == null) {
            manager.createNotificationChannel(
                NotificationChannel(
                    CHANNEL_QUIET,
                    context.getString(R.string.quiet_channel_name),
                    NotificationManager.IMPORTANCE_LOW,
                ).apply {
                    description = context.getString(R.string.quiet_channel_description)
                    setShowBadge(true)
                },
            )
        }
        if (manager.getNotificationChannel(CHANNEL_LOW) == null) {
            manager.createNotificationChannel(
                NotificationChannel(
                    CHANNEL_LOW,
                    context.getString(R.string.low_channel_name),
                    NotificationManager.IMPORTANCE_LOW,
                ).apply {
                    description = context.getString(R.string.low_channel_description)
                    setShowBadge(true)
                },
            )
        }
        if (manager.getNotificationChannel(CHANNEL_REMINDER) == null) {
            manager.createNotificationChannel(
                NotificationChannel(
                    CHANNEL_REMINDER,
                    context.getString(R.string.reminder_channel_name),
                    NotificationManager.IMPORTANCE_DEFAULT,
                ).apply {
                    description = context.getString(R.string.reminder_channel_description)
                    setShowBadge(false)
                },
            )
        }
    }

    /** 午後 10 時〜午前 6 時か。 */
    private fun isQuietHours(): Boolean {
        val hour = Calendar.getInstance().get(Calendar.HOUR_OF_DAY)
        return hour >= 22 || hour < 6
    }

    private fun channelFor(importance: String): String = when (importance) {
        "urgent" -> CHANNEL_ALERTS
        "normal" -> CHANNEL_LOW
        else -> if (isQuietHours()) CHANNEL_QUIET else CHANNEL_ID
    }

    /**
     * 通知を出す。権限が無いときは false。
     *
     * @param id 通知 ID（msg_id の下位 31 ビット）
     * @param importance "urgent" / "important" / "normal"
     * @param msgId タップで開く詳細の msg_id（無ければ null）
     */
    fun show(
        context: Context,
        id: Int,
        title: String,
        body: String,
        groupCode: Int,
        importance: String = "important",
        msgId: Long? = null,
    ): Boolean {
        if (!canNotify(context)) {
            Log.i(TAG, "通知権限が無いため出しません")
            return false
        }
        ensureChannel(context)
        val open = Intent(context, MainActivity::class.java).apply {
            action = Intent.ACTION_MAIN
            addCategory(Intent.CATEGORY_LAUNCHER)
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
            putExtra(EXTRA_GROUP_CODE, groupCode)
            if (msgId != null) {
                putExtra(EXTRA_MSG_ID, msgId)
            }
        }
        val pending = PendingIntent.getActivity(
            context,
            id,
            open,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val urgent = importance == "urgent"
        val notification = NotificationCompat.Builder(context, channelFor(importance))
            .setSmallIcon(R.drawable.ic_stat_kairanban)
            .setContentTitle(title)
            .setContentText(body)
            .setStyle(NotificationCompat.BigTextStyle().bigText(body))
            .setContentIntent(pending)
            .setAutoCancel(true)
            .setPriority(
                when (importance) {
                    "urgent" -> NotificationCompat.PRIORITY_MAX
                    "normal" -> NotificationCompat.PRIORITY_LOW
                    else -> NotificationCompat.PRIORITY_HIGH
                },
            )
            .setCategory(
                if (urgent) NotificationCompat.CATEGORY_ALARM else NotificationCompat.CATEGORY_MESSAGE,
            )
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .setGroup(if (urgent) CHANNEL_ALERTS else CHANNEL_ID)
            .apply {
                if (urgent) {
                    setVibrate(longArrayOf(0, 500, 300, 500, 300, 500))
                    setLights(Color.RED, 500, 500)
                }
                // Android 7.x にはチャネルがないので、音と振動を通知ごとに指定する
                // （チャネルと同じく、夜間と「ふだん」は鳴らさない）。
                if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
                    when (channelFor(importance)) {
                        CHANNEL_ALERTS -> setDefaults(NotificationCompat.DEFAULT_SOUND)
                        CHANNEL_ID -> setDefaults(NotificationCompat.DEFAULT_ALL)
                    }
                }
            }
            .build()
        return try {
            NotificationManagerCompat.from(context).notify(id, notification)
            true
        } catch (e: SecurityException) {
            Log.w(TAG, "通知を出せません", e)
            false
        }
    }

    /** 出した通知を消す（取り消された避難情報など）。 */
    fun cancel(context: Context, id: Int) {
        NotificationManagerCompat.from(context).cancel(id)
    }

    /** 確認通知（「回覧板の 確認です。災害では ありません」）を出す。 */
    fun showReminder(context: Context, title: String, body: String): Boolean {
        if (!canNotify(context)) {
            return false
        }
        ensureChannel(context)
        val open = Intent(context, MainActivity::class.java).apply {
            action = Intent.ACTION_MAIN
            addCategory(Intent.CATEGORY_LAUNCHER)
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
        }
        val pending = PendingIntent.getActivity(
            context,
            REMINDER_NOTIFICATION_ID,
            open,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val notification = NotificationCompat.Builder(context, CHANNEL_REMINDER)
            .setSmallIcon(R.drawable.ic_stat_kairanban)
            .setContentTitle(title)
            .setContentText(body)
            .setStyle(NotificationCompat.BigTextStyle().bigText(body))
            .setContentIntent(pending)
            .setAutoCancel(true)
            .setPriority(NotificationCompat.PRIORITY_DEFAULT)
            .setCategory(NotificationCompat.CATEGORY_REMINDER)
            .build()
        return try {
            NotificationManagerCompat.from(context).notify(REMINDER_NOTIFICATION_ID, notification)
            true
        } catch (e: SecurityException) {
            Log.w(TAG, "確認通知を出せません", e)
            false
        }
    }
}
