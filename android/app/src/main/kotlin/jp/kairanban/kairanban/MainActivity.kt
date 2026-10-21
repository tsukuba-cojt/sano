package jp.kairanban.kairanban

import android.content.Intent
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity

/**
 * キャッシュ済み FlutterEngine（"main"）を使う Activity。
 *
 * 画面を閉じてもエンジンは破棄しない。実行時権限や設定画面の結果は BleBridge に渡す。
 */
class MainActivity : FlutterActivity() {

    private val app: KairanApplication
        get() = application as KairanApplication

    override fun onCreate(savedInstanceState: Bundle?) {
        // FlutterActivity がキャッシュを引く前にエンジンの存在を保証する。
        app.ensureEngine()
        super.onCreate(savedInstanceState)
    }

    override fun getCachedEngineId(): String = KairanApplication.ENGINE_ID

    override fun shouldDestroyEngineWithHost(): Boolean = false

    override fun onResume() {
        super.onResume()
        app.bleBridge.onActivityResumed()
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        app.bleBridge.onRequestPermissionsResult(requestCode, permissions, grantResults)
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        app.bleBridge.onActivityResult(requestCode, resultCode, data)
    }
}
