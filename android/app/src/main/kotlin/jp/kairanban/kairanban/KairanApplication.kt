package jp.kairanban.kairanban

import android.app.Application
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugins.GeneratedPluginRegistrant
import jp.kairanban.kairanban.ble.BleBridge

/**
 * アプリ全体で 1 つの FlutterEngine を保持する Application。
 *
 * プロセス起動時に Dart の `main()` を実行し、[FlutterEngineCache] に "main" として登録する。
 * MainActivity はこのエンジンを使うため、画面を閉じても Dart 側の同期ロジックは生き続ける。
 * BOOT_COMPLETED → [MeshService] 起動の経路でも、Application 生成時にエンジンが作られる。
 */
class KairanApplication : Application() {

    /** BLE の MethodChannel / EventChannel 実装。エンジンと同じ寿命。 */
    lateinit var bleBridge: BleBridge
        private set

    override fun onCreate() {
        super.onCreate()
        ensureEngine()
    }

    /** キャッシュ済みエンジンを返す。無ければ生成して Dart を起動する。 */
    fun ensureEngine(): FlutterEngine {
        FlutterEngineCache.getInstance().get(ENGINE_ID)?.let { return it }

        // プラグインは自分で登録するので自動登録は切る（二重登録の警告を避ける）。
        val engine = FlutterEngine(this, null, false)
        if (!::bleBridge.isInitialized) {
            bleBridge = BleBridge(this)
        }
        GeneratedPluginRegistrant.registerWith(engine)
        engine.plugins.add(bleBridge)

        // チャンネル登録を済ませてから Dart を走らせる（最初の呼び出しを取りこぼさない）。
        engine.dartExecutor.executeDartEntrypoint(DartExecutor.DartEntrypoint.createDefault())
        FlutterEngineCache.getInstance().put(ENGINE_ID, engine)
        return engine
    }

    companion object {
        /** FlutterEngineCache のキー。 */
        const val ENGINE_ID = "main"
    }
}
