package jp.kairanban.kairanban

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log

/**
 * 月 1 回の確認通知（docs/08 C07）。
 *
 * Dart の `scheduleReminder{title, body, at}` で [schedule] が AlarmManager に 1 回限りの
 * 非正確アラームを入れ、時刻が来るとこの Receiver が通知を出す。予約内容は SharedPreferences に
 * 残し、端末の再起動後は [BootReceiver] が入れ直す。アプリを開くたびに Dart が予約し直すので、
 * 実際に鳴るのは 14 日以上開いていない端末だけになる。
 */
class ReminderReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != ACTION_FIRE) return
        val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        val title = prefs.getString(KEY_TITLE, null) ?: context.getString(R.string.reminder_default_title)
        val body = prefs.getString(KEY_BODY, null) ?: context.getString(R.string.reminder_default_body)
        prefs.edit().remove(KEY_AT).apply()
        NoticeNotifier.showReminder(context, title, body)
    }

    companion object {
        private const val TAG = "ReminderReceiver"
        private const val ACTION_FIRE = "jp.kairanban.REMINDER"
        private const val PREFS_NAME = "kairanban_reminder"
        private const val KEY_TITLE = "title"
        private const val KEY_BODY = "body"
        private const val KEY_AT = "at"
        private const val REQUEST_CODE = 0x4B10

        private fun pendingIntent(context: Context): PendingIntent {
            val intent = Intent(context, ReminderReceiver::class.java).setAction(ACTION_FIRE)
            return PendingIntent.getBroadcast(
                context,
                REQUEST_CODE,
                intent,
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
            )
        }

        /** [atMillis]（Unix ミリ秒）に 1 回限りの確認通知を予約する。既存の予約は置き換える。 */
        fun schedule(context: Context, title: String, body: String, atMillis: Long) {
            context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
                .edit()
                .putString(KEY_TITLE, title)
                .putString(KEY_BODY, body)
                .putLong(KEY_AT, atMillis)
                .apply()
            val alarm = context.getSystemService(AlarmManager::class.java) ?: return
            val pending = pendingIntent(context)
            alarm.cancel(pending)
            if (atMillis <= System.currentTimeMillis() + 60_000) {
                Log.i(TAG, "予約時刻が近すぎるため予約しません")
                return
            }
            try {
                // 正確さは要らない（数十分ずれてよい）ので、Doze でも届く非正確アラームにする。
                alarm.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, atMillis, pending)
            } catch (e: SecurityException) {
                Log.w(TAG, "確認通知を予約できません", e)
            }
        }

        /** 予約を取り消す。 */
        fun cancel(context: Context) {
            context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE).edit().clear().apply()
            val alarm = context.getSystemService(AlarmManager::class.java) ?: return
            alarm.cancel(pendingIntent(context))
        }

        /** 再起動後に、まだ先の予約が残っていれば入れ直す。 */
        fun rescheduleAfterBoot(context: Context) {
            val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            val at = prefs.getLong(KEY_AT, 0L)
            if (at <= 0L) return
            val title = prefs.getString(KEY_TITLE, null) ?: return
            val body = prefs.getString(KEY_BODY, null) ?: return
            if (at <= System.currentTimeMillis()) {
                // 再起動中に過ぎていたらすぐ出す。
                NoticeNotifier.showReminder(context, title, body)
                prefs.edit().remove(KEY_AT).apply()
                return
            }
            schedule(context, title, body, at)
        }
    }
}
