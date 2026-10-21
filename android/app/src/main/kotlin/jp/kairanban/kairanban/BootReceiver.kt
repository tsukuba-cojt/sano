package jp.kairanban.kairanban

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log

/**
 * 端末の再起動後に [MeshService] を再開する。
 *
 * Dart 側が `shared_preferences` の `mesh.enabled`（実際のキーは "flutter." 接頭辞付き）に
 * true を保存している場合だけ起動する。サービス起動 → Application でエンジン生成 →
 * Dart が設定を読んで自動的に `start` を呼ぶ。
 */
class BootReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Intent.ACTION_BOOT_COMPLETED) return
        ReminderReceiver.rescheduleAfterBoot(context)
        val prefs = context.getSharedPreferences(FLUTTER_PREFS_NAME, Context.MODE_PRIVATE)
        val enabled = try {
            prefs.getBoolean(MESH_ENABLED_KEY, false)
        } catch (e: ClassCastException) {
            // 想定外の型で保存されていた場合は再開しない。
            false
        }
        if (!enabled) {
            Log.d(TAG, "mesh.enabled が false のため再開しない")
            return
        }
        try {
            MeshService.start(context)
        } catch (e: RuntimeException) {
            Log.w(TAG, "MeshService の起動に失敗", e)
        }
    }

    companion object {
        private const val TAG = "BootReceiver"

        /** shared_preferences（Android 実装）が使う SharedPreferences 名。 */
        private const val FLUTTER_PREFS_NAME = "FlutterSharedPreferences"

        /** Dart 側のキー `mesh.enabled` に "flutter." 接頭辞が付いたもの。 */
        private const val MESH_ENABLED_KEY = "flutter.mesh.enabled"
    }
}
